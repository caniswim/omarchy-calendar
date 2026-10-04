"""iCalendar feeds as a calendar source.

Why this exists alongside gws and eds: Google publishes every calendar at a
private iCal address (Settings > your calendar > Integrate calendar > Secret
address in iCal format). Reading that needs no Google Cloud project, no OAuth
client, no consent screen and no refresh token, just the URL. The trade is
that it is read only, and Google refreshes the feed on its own schedule, so a
change can take a while to show up.

Any other https iCal feed (Nextcloud, Outlook, Fastmail, a webcal:// link)
works the same way.

Like eds, this emits Google Calendar event resources rather than contract
rows, so normalization, deduplication and validation are shared.

The icalendar imports are deliberately lazy, so the module stays importable
on a machine without python-icalendar and python-recurring-ical-events.
"""

import hashlib
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta

from .eds import build_event
from .errors import SyncError

FETCH_TIMEOUT = 30
FALLBACK_COLOR = "#4285f4"
USER_AGENT = "omarchy-calendar-sync"


class IcsError(SyncError):
    """A feed could not be fetched or parsed."""


class IcsMissing(IcsError):
    """python-icalendar or python-recurring-ical-events is not installed."""


def _load_libs():
    try:
        import icalendar
        import recurring_ical_events

        return icalendar, recurring_ical_events
    except ImportError as error:
        raise IcsMissing(
            "%s; install python-icalendar and python-recurring-ical-events"
            % error
        ) from error


def feed_url(value):
    """The fetchable URL for a configured feed. webcal:// is https://."""
    text = str(value or "").strip()
    if text.startswith("webcal://"):
        text = "https://" + text[len("webcal://"):]
    return text


def redact(url):
    """A URL safe to log. The path of a private feed is the credential."""
    text = feed_url(url)
    scheme, _, rest = text.partition("://")
    host = rest.split("/", 1)[0]
    return "%s://%s/..." % (scheme, host) if host else "(no url)"


def feed_id(url):
    """A stable calendar id that does not leak the secret URL into the file."""
    return "ics-" + hashlib.sha256(feed_url(url).encode()).hexdigest()[:12]


SECRET_HINT = (
    "use \"Secret address in iCal format\" under Settings > the calendar > "
    "Integrate calendar; it looks like .../ical/<id>/private-<code>/basic.ics"
)


def url_problem(value):
    """Why a URL is not a usable feed, or blank when it looks fine.

    Google shows the public address and the embed link right beside the
    secret one, and both are easy to copy by mistake.
    """
    url = feed_url(value)
    if not url.startswith(("https://", "http://")):
        return "expected an https:// or webcal:// address"
    if "calendar.google.com" in url:
        if "/embed" in url:
            return "that is the embed link, a web page rather than a feed; " + SECRET_HINT
        if "/public/" in url:
            return ("that is the public address, which only works for a "
                    "calendar shared publicly; " + SECRET_HINT)
    return ""


def parse_feeds(raw):
    """Normalize the `ics` config value into a list of {url, name, color}.

    Accepts a single URL string, a list of URL strings, or a list of objects
    with `url` and optional `name` and `color`.
    """
    if isinstance(raw, (str, dict)):
        raw = [raw]
    feeds = []
    for entry in raw or []:
        if isinstance(entry, str):
            entry = {"url": entry}
        if not isinstance(entry, dict):
            continue
        url = feed_url(entry.get("url"))
        if not url:
            continue
        feeds.append(
            {
                "url": url,
                "name": str(entry.get("name") or "").strip(),
                "color": str(entry.get("color") or "").strip(),
            }
        )
    return feeds


def _http_get(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
        return response.read()


def to_node(value, local_tz):
    """A date or datetime from icalendar as a Google start/end node.

    A floating time (no TZID, no Z) means "local time wherever you are" in
    iCalendar, so it is pinned to the local zone rather than refused.
    """
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=local_tz)
        return {"dateTime": value.isoformat()}
    if isinstance(value, date):
        return {"date": value.isoformat()}
    return None


def _text(component, name):
    value = component.get(name)
    return str(value) if value is not None else ""


def _own_partstat(component, identity):
    """The PARTSTAT of the attendee matching `identity`, or blank."""
    if not identity:
        return ""
    wanted = "mailto:%s" % identity.strip().lower()
    attendees = component.get("ATTENDEE")
    if attendees is None:
        return ""
    if not isinstance(attendees, list):
        attendees = [attendees]
    for attendee in attendees:
        if str(attendee).strip().lower() == wanted:
            return str(getattr(attendee, "params", {}).get("PARTSTAT", ""))
    return ""


def occurrence_to_event(component, local_tz, identity=""):
    """One expanded VEVENT occurrence as a Google event resource."""
    start = component.get("DTSTART")
    if start is None:
        return None
    start_value = start.dt

    end_value = None
    if component.get("DTEND") is not None:
        end_value = component["DTEND"].dt
    elif component.get("DURATION") is not None:
        end_value = start_value + component["DURATION"].dt
    elif isinstance(start_value, datetime):
        end_value = start_value
    else:
        # RFC 5545: an all-day event without DTEND lasts one day.
        end_value = start_value + timedelta(days=1)

    start_node = to_node(start_value, local_tz)
    end_node = to_node(end_value, local_tz)
    if start_node is None:
        return None

    status = _text(component, "STATUS").upper()

    return build_event(
        uid=_text(component, "UID"),
        start_node=start_node,
        end_node=end_node,
        summary=_text(component, "SUMMARY"),
        location=_text(component, "LOCATION"),
        status="cancelled" if status == "CANCELLED" else "",
        conference_url=_text(component, "X-GOOGLE-CONFERENCE"),
        partstat=_own_partstat(component, identity),
        recurrence_key=start_node.get("dateTime") or start_node.get("date"),
    )


class Ics:
    """A calendar client backed by one or more iCalendar URLs.

    Presents the same surface as Gws and Eds -- check, version, calendars,
    events -- so cli.run drives it without knowing which it has.
    """

    SOURCE_NAME = "ics"

    # Feeds are read only.
    can_write = False

    def __init__(self, feeds, identity="", fetch=None, local_tz=None):
        self._feeds = parse_feeds(feeds)
        self._identity = identity
        self._fetch = fetch or _http_get
        self._local_tz = local_tz
        self._parsed = {}

    def _tz(self):
        if self._local_tz is None:
            from .cli import resolve_local_timezone

            self._local_tz = resolve_local_timezone()
        return self._local_tz

    def version(self):
        icalendar, _rie = _load_libs()
        parts = []
        for piece in str(getattr(icalendar, "__version__", "0")).split("."):
            digits = "".join(ch for ch in piece if ch.isdigit())
            parts.append(int(digits or 0))
        return tuple(parts[:3]) or (0,)

    def check(self):
        _load_libs()
        if not self._feeds:
            raise IcsError(
                "no feeds configured; add your calendar's secret iCal address "
                "under \"ics\" in ~/.config/omarchy/calendar-sync.json"
            )

    def calendars(self):
        icalendar, _rie = _load_libs()
        found = []
        failures = []
        for feed in self._feeds:
            url = feed["url"]
            try:
                body = self._fetch(url)
                calendar = icalendar.Calendar.from_ical(body)
            except (urllib.error.URLError, OSError, ValueError) as error:
                # One broken feed must not sink the others.
                problem = url_problem(url)
                reason = "%s (%s)" % (error, problem) if problem else str(error)
                failures.append("%s: %s" % (redact(url), reason))
                print("skipping %s: %s" % (redact(url), reason))
                continue

            ident = feed_id(url)
            self._parsed[ident] = calendar
            found.append(
                {
                    "id": ident,
                    "name": feed["name"]
                    or _text(calendar, "X-WR-CALNAME")
                    or redact(url),
                    "color": feed["color"]
                    or _text(calendar, "X-APPLE-CALENDAR-COLOR")
                    or FALLBACK_COLOR,
                }
            )

        if failures and not found:
            # Every feed failed. Writing an empty file would wipe the panel.
            raise IcsError("; ".join(failures))
        return found

    def events(self, calendar_id, time_min, time_max):
        _icalendar, rie = _load_libs()
        calendar = self._parsed.get(calendar_id)
        if calendar is None:
            raise IcsError("calendar %s was never fetched" % calendar_id)

        start = datetime.fromisoformat(time_min)
        end = datetime.fromisoformat(time_max)
        try:
            occurrences = rie.of(calendar).between(start, end)
        except Exception as error:
            raise IcsError("cannot expand %s: %s" % (calendar_id, error))

        tz = self._tz()
        events = []
        for component in occurrences:
            event = occurrence_to_event(component, tz, self._identity)
            if event is not None:
                events.append(event)
        return events

    def auth_hint(self, _cfg):
        return (
            "check the feed URL in ~/.config/omarchy/calendar-sync.json; a "
            "Google secret address stops working if it is reset in Google "
            "Calendar settings"
        )
