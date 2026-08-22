# Privacy policy

## The short version

Barosense keeps everything on your iPhone. Your check-ins, your notes, your tags, your
Apple Health readings and your pressure history are stored on the device and are never
uploaded to us. There is no account and no server holding your history.

One thing leaves the device: a request to Apple Weather carrying your **approximate area
and the time**, so the app can fetch a pressure forecast. Nothing about how you feel goes
with it. You can switch that off in Settings, and then nothing leaves at all.

Everything below says the same thing in more detail.

Effective: {{effectiveDate}} · Applies to Barosense {{appVersion}}

## 1. Who this policy is from

- Provider: {{provider}}
- Contact: {{contactEmail}}

Where this policy says "we", it means the provider named above. Where it says "the app" or
"Barosense", it means the Barosense application on your iPhone and Apple Watch.

## 2. What Barosense stores on your device

All of the following is written to storage on your own device, inside the app's own
container.

### Profile

- The name you choose to give, if you give one.
- Your age in whole years, if you give it. A birth date is never asked for — it is more
  identifying than the question needs.
- Gender, if you choose one.
- A profile photo, if you pick one. It is downscaled to a thumbnail before it is stored.
- How often harder periods come around for you, and roughly how long they last, as coarse
  ranges rather than exact figures.
- The moments you accepted these documents, asked to connect Apple Health, and finished
  onboarding.

Every field is optional. The app is built to work for someone who skipped all of them.

### Check-ins

- When you logged it.
- How intense it was, on the 1–10 scale the form draws.
- Any tags you attached, and the tag vocabulary itself, which is yours to edit.
- Anything you recorded taking around that time.
- Your free-text note, if you wrote one.

Notes and medication entries are recorded and shown back to you. They are never turned into
inputs for any calculation, and they never join an outbound request of any kind.

### Sensor and environment data

- Barometric pressure readings from your iPhone's built-in barometer, with their
  timestamps, taken at most once every 15 minutes.
- Coordinates identifying the general area a batch of readings belongs to, rounded to
  0.1° — about 11 km — before they are written down.
- Pressure forecast values fetched from Apple Weather, kept so the chart still has a
  forward curve when the device is offline.

### Apple Health readings

When, and only when, you connect Apple Health, Barosense reads four kinds of sample and
stores copies of them alongside your check-ins:

- Sleep analysis
- Heart rate
- Resting heart rate
- Blood oxygen

Barosense has **read** access only. It has never had permission to write to Apple Health
and does not ask for it. It requests no other Health data type. If a type is not on the
list above, the app does not have it.

### Notification records

A short record of which notifications were scheduled, sent or suppressed, so that the app
can hold itself to its own daily cap.

## 3. What leaves your device

### Apple Weather (WeatherKit)

When Apple Weather is enabled in Settings, Barosense asks Apple's WeatherKit service for a
pressure forecast. The request carries your area rounded to about 11 km, and the time.

It carries no check-ins, no notes, no tags, no Apple Health data, no profile fields, no
device identifier and no account identifier — there is no account.

That request is handled by Apple under Apple's own privacy policy, not ours. We receive
neither the request nor the response.

Turning Apple Weather off in Settings stops those requests. The forecast then comes from a
curve fitted to your own barometer readings: shorter and rougher, still on-device.

### Your Apple Watch

If you use the Watch app, pressure readings pass between your iPhone and your paired Watch
over Apple's device-to-device link. That traffic stays between your two devices.

### Anything you export yourself

The report in Settings produces a PDF on your device. Where it goes next is entirely your
decision, and once you have shared it, it is outside the app's control and outside this
policy.

## 4. What Barosense never does

- It has no user accounts and no sign-in.
- It has no analytics, no crash-reporting service and no advertising SDK.
- It has no third-party trackers of any kind.
- It sells nothing, and shares nothing with data brokers.
- It does not sync your health-related data to iCloud. Every store the app creates has
  iCloud sync explicitly switched off.
- It does not write to Apple Health.
- It does not ask for precise location, ever.

## 5. Backups

If you back your iPhone up, the app's data is included in that backup the same way any
app's data is. Whether that backup is local or in iCloud, and how it is encrypted, is
between you and Apple. We have no access to it.

## 6. How long data is kept

- Pressure readings: up to five years, then the oldest are dropped automatically. Response
  to weather is plausibly seasonal, and five years is five passes over the same season.
- Everything else: until you delete it.

Deleting the app removes its container, and with it everything listed in section 2.

## 7. Your choices and your rights

Because your data never leaves your device, you exercise these directly in the app rather
than by asking us — we could not act on your data even if you asked, as we do not hold it.

- **See your data.** It is all in the app: History, Log, and Settings › Generate PDF report.
- **Take a copy.** Settings › Generate PDF report produces a PDF of any period you choose.
- **Correct it.** Profile fields and tags are editable in Settings. Removing a single
  check-in is not possible yet.
- **Erase it.** Settings › Delete my data empties everything in section 2 and returns the
  app to onboarding. It cannot be undone. Your Apple Health data is untouched — it was only
  ever read.
- **Withdraw a permission.** Apple Health access is revoked in the Health app; location in
  iOS Settings; notifications in iOS Settings; Apple Weather in Barosense's own Settings.
  The app degrades and keeps running in every case.

If you are in the EU, the UK or another jurisdiction with equivalent rights, the same
applies: the reason there is no request to send us is that there is no copy for us to hold.

## 8. Children

Barosense is not directed at children and is not intended for use by anyone under 16. We do
not knowingly collect anything from a child — in the strict sense we do not knowingly
collect anything from anyone, because nothing reaches us.

## 9. Security

Your data is protected by the device's own protections: iOS app sandboxing and file-level
encryption, which apply whenever your iPhone is locked with a passcode, Face ID or Touch ID.

Setting a passcode is the single most useful thing you can do for the privacy of what is in
this app. Without one, iOS's file encryption has nothing to protect the data with.

## 10. Changes to this policy

If this policy changes, the effective date at the top changes with it, and a material change
will be shown in the app rather than left for you to find.

## 11. Contact

Questions about this policy, or about anything in it:

- {{contactEmail}}

## A note on the blanks

Where this document shows "—", the detail is not settled yet. That is deliberate: a
placeholder is honest, and a made-up company name or an address nobody answers would not be.
Those entries will be filled in before the app is published.
