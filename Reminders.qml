pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Strings.js" as Strings

// Desktop notifications at each event's reminder times. Lives in the bar
// widget rather than the panel because the widget is always loaded.
//
// Omarchy's notification cards draw no action buttons, so a reminder is
// click-only: clicking it (also from the history) opens the meeting or the
// event page. Snoozing is offered by the panel instead, through snooze() and
// recentlyFired.
//
// What has been sent is kept in a small JSON file under XDG_RUNTIME_DIR, so a
// shell reload never repeats a reminder, while a reboot (which clears the
// directory) starts clean without flooding the day's backlog.
Scope {
  id: root

  // Already filtered by the widget (hidden calendars, declined).
  property var events: []
  property bool enabled: true
  property string language: "en"
  property string timeFormat: "HH:mm"
  // Several bar surfaces (one per monitor) each have a widget, and only one
  // of them may send, or every reminder would arrive once per screen.
  property var isLeader: function() { return true }

  property string statePath: (Quickshell.env("XDG_RUNTIME_DIR") || ((Quickshell.env("HOME") || "") + "/.cache"))
    + "/tmn73.calendar-reminders.json"
  property string notifier: Quickshell.env("OMARCHY_PATH")
    ? Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-notification-send"
    : "omarchy-notification-send"

  // Event key ("id|start", see eventKey) → when its reminder was sent, for
  // the last snoozeWindowMs. The panel offers "Snooze" while an event is in
  // here.
  property var recentlyFired: ({})
  readonly property int snoozeWindowMs: 15 * minuteMs

  readonly property int tickMs: 20000
  readonly property int minuteMs: 60 * 1000
  readonly property string glyph: "󰃭"

  // { since, fired: { reminderKey: startMs }, recent: { eventKey: firedAtMs },
  //   snoozed: { eventKey: { fireAtMs, event } } }. `since` is when the file
  // was created: nothing due before it is sent, which is what keeps a first
  // run from replaying the whole day.
  property var store: null

  function eventKey(event) {
    return Model.text(event && event.id) + "|" + Model.text(event && event.start)
  }

  function canSnooze(event, nowMs) {
    var firedAt = recentlyFired[eventKey(event)]
    return firedAt !== undefined && nowMs - firedAt < snoozeWindowMs
  }

  // Sends the reminder for `event` again in `minutes`, even if the event has
  // started by then, as long as it has not ended.
  function snooze(event, minutes) {
    if (!event || !store) return
    var next = copyStore(store)
    var key = eventKey(event)
    next.snoozed[key] = { fireAtMs: Date.now() + Math.max(1, Number(minutes) || 5) * minuteMs, event: slimEvent(event) }
    delete next.recent[key]
    commit(next)
  }

  // A one-off toast that is not a reminder ("No meeting to join").
  function notice(headline) {
    send(headline, "", "", "low")
  }

  // ---- Store

  function emptyStore(nowMs) {
    return { since: nowMs, fired: {}, recent: {}, snoozed: {} }
  }

  function copyStore(s) {
    return JSON.parse(JSON.stringify(s))
  }

  function parseStore(raw) {
    try {
      var parsed = JSON.parse(raw)
      if (!parsed || !isFinite(Number(parsed.since))) return null
      return {
        since: Number(parsed.since),
        fired: parsed.fired || {},
        recent: parsed.recent || {},
        snoozed: parsed.snoozed || {}
      }
    } catch (error) {
      return null
    }
  }

  function adopt(next) {
    root.store = next
    root.recentlyFired = next.recent
  }

  function commit(next) {
    var changed = JSON.stringify(next) !== JSON.stringify(store)
    adopt(next)
    if (changed) stateFile.setText(JSON.stringify(next))
  }

  // Only what a snoozed reminder needs to be rebuilt after a shell reload.
  function slimEvent(event) {
    return {
      id: event.id, start: event.start, end: event.end, allDay: event.allDay === true,
      dateKey: event.dateKey, title: event.title, location: event.location,
      meetingUrl: event.meetingUrl, eventUrl: event.eventUrl
    }
  }

  function pruneRecent(recent, nowMs) {
    var next = {}
    for (var key in recent)
      if (nowMs - Number(recent[key]) < snoozeWindowMs) next[key] = Number(recent[key])
    return next
  }

  // ---- Sending

  function tick(nowMs) {
    if (!enabled || !store || !isLeader()) return
    var next = copyStore(store)
    next.fired = Model.pruneFired(next.fired, nowMs)

    var due = Model.dueReminders(events, nowMs, next.fired, { notBeforeMs: next.since })
    for (var i = 0; i < due.length; i++) {
      notify(due[i].event, nowMs)
      next.recent[eventKey(due[i].event)] = nowMs
    }
    next.fired = Model.markFired(next.fired, due)

    for (var key in next.snoozed) {
      var snoozed = next.snoozed[key]
      if (!snoozed || Number(snoozed.fireAtMs) > nowMs) continue
      if (Model.timeRange(snoozed.event).end > nowMs) {
        notify(snoozed.event, nowMs)
        next.recent[key] = nowMs
      }
      delete next.snoozed[key]
    }

    next.recent = pruneRecent(next.recent, nowMs)
    commit(next)
  }

  function notify(event, nowMs) {
    var url = Model.meetingUrlFor(event) || Model.eventUrlFor(event)
    send(headline(event, nowMs), body(event, nowMs), url, "normal")
  }

  function titleOf(event) {
    var title = Model.text(event.title).trim()
    return Model.truncateTitle(title || Strings.tr(language, "common.noTitle"), 80)
  }

  // "Standup in 10 min", "Standup is starting"; an all-day event is just its
  // title, the day goes in the body.
  function headline(event, nowMs) {
    if (event.allDay) return titleOf(event)
    var minutes = Math.ceil((Model.timeRange(event).start - nowMs) / minuteMs)
    return minutes >= 1
      ? Strings.tr(language, "notify.title", [titleOf(event), Model.spanText(minutes, language)])
      : Strings.tr(language, "notify.titleNow", [titleOf(event)])
  }

  // "13:00–13:45 · Google Meet", "Tomorrow · 09:00–09:30 · Room 4",
  // "Tomorrow · all day".
  function body(event, nowMs) {
    if (event.allDay)
      return capitalized(Model.relativeTime(event, nowMs, language)) + " · " + Strings.tr(language, "insp.allDay")

    var range = Model.timeRange(event)
    var parts = []
    var startKey = Model.keyForMs(range.start)
    var todayKey = Model.keyForMs(nowMs)
    if (startKey !== todayKey) {
      parts.push(Model.relativeDayLabel(startKey, todayKey, language)
        || capitalized(Qt.locale(Strings.localeName(language)).toString(new Date(range.start), "dddd")))
    }
    var times = Qt.formatDateTime(new Date(range.start), timeFormat)
    if (range.end > range.start) times += "–" + Qt.formatDateTime(new Date(range.end), timeFormat)
    parts.push(times)

    var where = Model.meetingHost(Model.meetingUrlFor(event)) || Model.truncateTitle(Model.text(event.location).trim(), 48)
    if (where) parts.push(where)
    return parts.join(" · ")
  }

  function capitalized(value) {
    var s = Model.text(value)
    return s.charAt(0).toUpperCase() + s.slice(1)
  }

  // omarchy-notification-send reads a leading "-g" or "--app-name=…" as an
  // option, so a title that happens to look like one gets a word joiner in
  // front and stays text.
  function positional(value) {
    return /^-/.test(value) ? "⁠" + value : value
  }

  // Argv arrays, never a shell string: titles and locations come from other
  // people's invitations. `--exec` has to be last.
  function send(title, text, url, urgency) {
    var primary = [notifier, "-g", glyph, "-u", urgency, positional(title), positional(text)]
    if (url) primary = primary.concat(["--exec", "xdg-open", url])
    var fallback = ["notify-send", "--app-name=" + Strings.tr(language, "notify.app"), "-u", urgency, "--", title, text]
    senderComponent.createObject(root, { command: primary, fallback: fallback, running: true })
  }

  Component {
    id: senderComponent

    // One process per notification, gone once it exits. A command that
    // cannot start at all (no omarchy-notification-send on this system)
    // reports running=false without ever having started.
    Process {
      property var fallback: null
      property bool began: false

      onStarted: began = true
      onRunningChanged: {
        if (running) return
        if (!began && fallback) senderComponent.createObject(root, { command: fallback, running: true })
        destroy()
      }
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    watchChanges: true
    printErrors: false

    onLoaded: root.adopt(root.parseStore(text()) || root.emptyStore(Date.now()))
    onLoadFailed: if (!root.store) root.commit(root.emptyStore(Date.now()))
    // The leader is the only writer, so a change it sees is its own write
    // coming back; the other screens pick it up for recentlyFired.
    onFileChanged: if (!root.isLeader()) reload()
  }

  Timer {
    interval: root.tickMs
    repeat: true
    running: root.enabled && root.store !== null
    triggeredOnStart: true
    onTriggered: root.tick(Date.now())
  }
}
