# Questions and answers

## Getting started

### What is Barosense?

Barosense records the barometric pressure around you, collects short check-ins about how
you feel, and puts the two side by side. The point is to make **your own** pattern visible
— whether shifts in the weather line up with your harder days, and by how much.

It is a tracking companion. It is not a source of answers about your body.

### Is this a substitute for a doctor?

No. Barosense is not medical advice and does not replace talking to a doctor. Everything
it shows is an observation about the history you logged yourself. Decisions about your
health belong with you and a professional.

### What can it do today?

Four things: show the current pressure and how fast it is moving; read a weather-trigger
value off the last six hours of change; keep your check-ins on the same timeline as that
curve; and extend the pressure curve a few days ahead.

The personal part — a pattern built from your own history rather than from general rules
about pressure — is still being built. Settings says so plainly under **Reset learned
data** while there is nothing learned yet.

### How much history does it need?

The pressure view works from the first day. For your own pattern, three to seven days of
check-ins is the target. Barosense is deliberately built to be worth something that early,
rather than to stay silent until it has months of data.

### How often should I check in?

Once a day is enough for a pattern to form. Add one whenever something changes noticeably.

Log the good stretches too. A history made only of hard days teaches the app that every day
is a hard day, and then nothing stands out.

## Pressure readings

### Where does the pressure number come from?

From the barometer built into your iPhone. It is a real sensor reading taken on your
device, not a figure downloaded from a weather service.

### Why is Barosense's number different from my weather app?

Because the two are measuring different things, and both are right.

Weather services publish **sea-level** pressure: the reading adjusted as if the station
stood at sea level, so that places at different elevations can be compared with each other.
Your iPhone measures **station** pressure — the actual air pressure where you are standing.

Roughly 1 hPa is lost for every 8 m of elevation. At 200 m above sea level your reading
will sit about 20 hPa below the forecast, permanently. Nothing is broken.

### Why does the pressure jump when I take a lift?

Because pressure falls as you go up, and ten floors moves the reading about as much as a
weather front does.

Barosense knows this. A reading that moves faster than weather physically can — more than
3 hPa in ten minutes — is counted as you changing altitude, not as weather, and is kept out
of the pattern. Synoptic pressure change stays under about 2 hPa an hour even in a rapidly
deepening system.

### What matters — the number, or the change?

The change. An absolute reading of 1008 hPa says very little on its own; a fall of 6 hPa
across six hours is the kind of movement people tend to notice in their check-ins.

That is why the app is built around rates of change over 3, 6 and 24 hours rather than
around today's figure.

### How far ahead does the pressure forecast reach?

With **Apple Weather** on, a few days. With it off, Barosense fits a curve to your own
recent readings instead, which reaches a few hours and is rougher.

### Why does it show a state rather than a yes or no?

Because a yes or no would be a claim Barosense cannot honestly make. Weather is one
influence among many and your history is limited. What it can say is that the conditions
your harder days have tended to come with are building — never that something will happen.

## Your data

### Does my data leave my iPhone?

No. Check-ins, notes, tags, Apple Health readings and pressure history are stored on your
device and are never uploaded. There is no account, no server holding your history, and no
analytics watching what you do in the app.

### Then what does Apple Weather send?

Your approximate area and the time, in order to fetch the pressure forecast — and nothing
else. No check-ins, nothing from Apple Health, no notes, no identifiers.

Coordinates are rounded to 0.1°, about 11 km, before they are stored or used. Barosense
asks iOS for **approximate** location only and never offers the precise option, because
nothing in the app has a use for it.

### Do you sell my data?

No. There is nothing to sell, because it never reaches us. Barosense carries no
advertising and no third-party trackers.

### Is my history in iCloud?

Not through Barosense. Every store the app writes is created with iCloud sync explicitly
switched off.

If you take an encrypted iPhone backup, Barosense's data is inside that backup, the same
way every app's data is. That backup is yours and Apple's, not ours.

### How do I delete everything?

**Settings › Delete my data.** It empties your profile, check-ins, tags, notes, medication
entries, and every pressure and Health reading Barosense has stored, then returns the app
to onboarding. It cannot be undone.

Your Apple Health data stays exactly where it is. Barosense only ever read it and never
wrote to it, so there is nothing of ours to remove from Health — and setting the app up
again will read it again.

### Can I delete a single check-in?

Not yet. Today the only removal is the full erase in Settings. Correcting or dropping one
entry is planned.

## Permissions

### Why does Barosense ask for Apple Health?

To read four things: sleep, heart rate, resting heart rate and blood oxygen. They sit
beside your check-ins so that a harder day has more context than pressure alone.

Barosense **reads** these and never writes anything back to Health. It asks for nothing
else — a permission with no feature behind it is a permission the app does not request.

### Do I have to connect Apple Health?

No. The app runs on check-ins and pressure alone; Health simply gives it more to work with.

You can revoke it at any time in the Health app, and Barosense carries on. iOS never tells
an app that a read was refused, so if the switch in Settings will not stay on, the Health
app is the only place that can settle what Barosense may see.

### Why does it want my location?

To know which area the pressure forecast should be about. Approximate location only,
rounded to about 11 km on the way into storage.

Refuse it and the forecast falls back to your own sensor readings — shorter and rougher,
but the app keeps working.

### What happens if I turn Apple Weather off?

Then nothing leaves your device at all. In exchange the forecast stops reaching days ahead
and becomes a few hours fitted from your own barometer.

## Notifications and battery

### Why did I not get a notification?

One of three reasons:

- Notifications are off for Barosense in **iOS Settings**.
- The check-in reminder is off in **Barosense › Settings**.
- The day's cap was already used. Barosense sends at most **3** notifications a day, across
  every kind, deliberately.

**Settings › Notifications today** shows how much of the cap the current day has used.

### Does Barosense drain my battery?

It is built not to. Pressure is recorded at most once every 15 minutes, and only while the
app is already awake — in the foreground, or during a background refresh iOS chose to
grant. There is no continuous sensor session and no polling loop.

iOS decides when background refresh happens, from your usage, charge state and Low Power
Mode. That is why readings arrive at irregular times, and why the app is designed to
tolerate gaps rather than to demand a fixed cadence.

## Reports and the Watch

### Can I share my history with someone?

Yes. **Settings › Generate PDF report** produces a PDF for a period you choose — your check-ins beside
the pressure — which you can then share however you like.

It is a record of what you logged. It is not an assessment, and it does not interpret
anything for the reader.

### What does the Apple Watch app do?

Today it shows the current pressure on your wrist. The iPhone owns the barometer and does
the recording; check-ins from the Watch and a watch-face complication are planned.

### How do I change the app's language?

**Settings › Language.** Everything Barosense draws changes immediately.

The prompts iOS draws itself — the Health and location permission dialogs — follow on the
next launch, because those belong to the system rather than to the app.

### Something looks wrong. Where do I write?

**Settings › Contact us.** That screen also carries the app version, which makes a report
much easier to match to a build.
