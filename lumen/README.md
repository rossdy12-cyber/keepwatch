# Lumen

A pro camera and photo/video editor for iPhone. Everything, including the AI, runs on the phone; nothing is uploaded.

## Camera
- **Manual controls:** exposure compensation (EV), ISO, shutter speed, white balance (temperature and tint) and manual
  focus. Tap a control to show its slider, and AUTO to hand it back to the camera.
- **Every lens** (0.5×, 1×, telephoto, front), plus **2×** on the main camera (a crop of its high-resolution sensor,
  as Apple's Camera does on iPhones without a 2× lens), a **Zoom (Z)** slider up to the camera's limit, pinch to zoom,
  and tap to focus and expose.
- **Video:** switch to VIDEO for 4K or HD at 24/30/60 fps, HEVC with sound and automatic stabilisation. The manual
  controls work while filming, and the thumbnail opens the clip in the video editor.
- **Formats:** HEIF, JPEG, **RAW** (Apple **ProRAW** on iPhones that have it, otherwise DNG) and **RAW+HEIF**.
- **Shooting aids:** live histogram, rule-of-thirds grid, a level that turns yellow when straight, 3 s / 10 s
  self-timer, flash, and a live readout of ISO, shutter speed, EV and colour temperature.

## Editor
Tap the thumbnail to edit the last shot, or the photo icon to open any photo or video from your library.
- **Looks:** 13 styles (Vivid, Golden Hour, Blockbuster, Film, Moody, Pastel, Chrome, Instant, Cross Process,
  Mono, Noir, Silver), each with a strength slider.
- **AI:** Magic Enhance (Apple's face-aware auto-correction), Subject pop and Background blur (the subject is found
  with Apple's Vision framework), and Reduce noise.
- **Light:** exposure, contrast, highlights, shadows, whites, blacks.
- **Colour:** temperature, tint, vibrance, saturation.
- **Detail:** clarity, sharpen, grain, vignette, fade.
- **Crop:** 1:1, 4:5, 3:2, 16:9, 2.39:1 and straighten.

Press and hold the photo to compare with the original, and double-tap a slider's name to reset it. RAW photos are
developed from the sensor data, so exposure, white balance and noise reduction have the most room. **Save** adds a
full-resolution HEIC copy to Photos (the original is kept); the share button sends it anywhere.

**AI upscale (on your NAS):** in the AI tab, **Upscale 2×** or **4×** sends the photo (with your edits) to the
lumen-ai app on TrueNAS (see `lumen-ai/`). It runs Real-ESRGAN on the NAS's processor and sends back a larger
photo, about 16 megapixels, that you carry on editing. Set the address and key once, from the lumen-ai app's logs.

**Videos:** looks, Magic Enhance, noise reduction, light, colour and detail, previewed live while the video plays.
Save exports a new video to Photos. Subject pop, background blur and crop are for photos only.

Build: GitHub **Actions → Build Lumen IPA**, download **Lumen-ipa** and install with Sideloadly or LiveContainer.
