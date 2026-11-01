# Jarvis Alexa skill

A private Alexa skill for your own Echo devices. It sends what you say to the Jarvis core at
`https://jarvis.nas-server.co.uk/api/alexa` and speaks its answer, in Jarvis's own voice where the core provides one.
The core already handles Alexa requests; this folder is the Amazon side.

- **"Alexa, open Jarvis"**, then talk to it. It keeps listening until you say "stop".
- **"Alexa, ask Jarvis how the NAS is doing"** / "…ask Jarvis anything on the cameras" for one question at a time.
- **"Alexa, ask Jarvis for my daily briefing"**.

It doesn't need publishing: a skill in **development** works on every Echo signed in to the same Amazon account.

## Set it up (developer console, about 10 minutes)

1. Go to <https://developer.amazon.com/alexa/console/ask> and sign in with **the same Amazon account as your Echo**.
2. **Create Skill**:
   - Name `Jarvis`, primary locale **English (UK)**.
   - Type **Other → Custom**, backend **Provision your own**.
   - Template **Start from Scratch**, then **Create skill**.
3. **Build → Interaction Model → JSON Editor**. Replace everything with [`skill-package/interactionModels/custom/en-GB.json`](skill-package/interactionModels/custom/en-GB.json),
   then **Save** and **Build skill**.
4. **Build → Endpoint**:
   - Choose **HTTPS**. Default Region: `https://jarvis.nas-server.co.uk/api/alexa`.
   - Certificate: **"My development endpoint is a sub-domain of a domain that has a wildcard certificate from a
     certificate authority"**. If testing says the certificate isn't valid, choose the "trusted certificate
     authority" option instead.
   - **Save**.
5. **Test** tab: switch testing to **Development**, type `open jarvis` and check that it answers.
6. On your Echo: **"Alexa, open Jarvis."** The skill also shows up in the Alexa app under **More → Skills & Games →
   Your Skills → Dev**.

If the console won't accept the one-word invocation name `jarvis`, use two words (for example `jarvis core`)
in the JSON's `invocationName`, then say "Alexa, open Jarvis Core".

`skill-package/` is also laid out for the ASK CLI (`ask deploy`) if you prefer that.

## Things to know

- **Alexa allows 8 seconds per answer.** Briefings and status answers take about a second, but free-form questions go
  to the core's AI and took 5–11 seconds in testing, so some long answers will fail with "There was a problem with
  the requested skill's response". The fix is on the Jarvis core: a faster model, shorter answers, or sending
  Alexa a "one moment" progressive response while it thinks.
- **Security:** `/api/alexa` doesn't currently check that requests really come from Amazon. Anyone who knows the
  address can talk to Jarvis through it. The core should verify Alexa's request signature, or at least the
  skill's application ID (shown in the console after you create the skill).
