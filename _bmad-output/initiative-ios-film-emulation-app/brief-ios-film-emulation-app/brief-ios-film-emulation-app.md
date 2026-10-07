---
title: "Product Brief: iOS Film Emulation App"
status: final
created: 2025-07-16
updated: 2025-07-16
---

# Product Brief: iOS Film Emulation App

## Executive Summary

A stripped-down iOS camera app that brings authentic film emulation to both photos and video, at impulse-buy pricing. It combines the best of two worlds: the simple, film-like shooting experience of mood.camera, extended to video with the RAW/Log capture quality of the Blackmagic Camera app — but without the complexity of either. Shoot now, pick your film stock later. One tap to apply. Save to camera roll. Done.

The app shoots RAW photos and Apple Log 2 video, bypassing Apple's processing pipeline entirely, then applies a post-processing chain of LUT, grain, halation, and glow to produce authentic film character. Manual controls — shutter speed, ISO, aperture — are there when you want them, invisible when you don't. Grain is treated as a first-class concern: ISO-driven, accurate to stock, naturalistic in motion.

Priced at $5/year or $10 lifetime, it's built for film enthusiasts who want the film look without the film workflow — and who've been underserved by apps that either lock you into real-time-only emulation, skip video entirely, or charge pro-level prices for state-of-the-art color science.

## The Problem

Film enthusiasts who want an authentic film look from their iPhone have no single app that does everything they need.

**mood.camera** comes closest to the experience of shooting real film — no peeking at results, no saving originals, just commit and move on. But it's photo-only. There's no video. And you can't apply a film stock after you've shot; the emulation is baked in at capture. If you want to experiment with different stocks on the same shot, you're out of luck.

**Blackmagic Camera** brings professional-grade video controls and Apple Log capture to the iPhone. It's a genuine filmmaking tool. But that's the problem: it's a filmmaking tool. The interface is built for sets and shoots, not for pulling out your phone and grabbing a 15-second film-look clip. And you can't apply LUTs or edit in-app — you need to move footage to a desktop editor.

**Dehancer** offers state-of-the-art film emulation with 86 stocks and a full editing suite for both photo and video. But it's priced like pro software, putting it out of reach for casual film enthusiasts who just want their phone shots to look like Portra.

The result: shooters cobble together workflows across multiple apps — capture in one, grade in another, share from a third — or they settle for an app that does one thing well and leaves the rest on the table. A simple, affordable, all-in-one film camera for photo and video doesn't exist.

## The Solution

A single iOS app that does two things well: captures photos and video with the simplicity of a film camera, and applies authentic film emulation — either at capture or after the fact.

**Shooting.** The camera is stripped to essentials. You pick a film stock, frame your shot, and shoot. Manual controls — shutter speed, ISO, and aperture (on iPhone Pro models) — are available with a tap. Lock one and the app auto-exposes to your preferred exposure value. But the default experience is point-and-shoot: pick a stock, press the button.

Behind the scenes, the app shoots RAW for photos and Apple Log 2 for video, bypassing Apple's processing entirely. No over-sharpening, no tone mapping, no "phone camera" look. Just a clean, flat capture ready for the emulation pipeline.

**Processing.** Every shot runs through LUT → grain → halation → glow. Grain is tied to the film stock's ISO: the slider controls both grain size and amount, and the pattern is accurate to the stock — not random noise. For video, grain is naturalistic and temporally coherent, not flickering static.

**Post-capture.** This is what sets the app apart. You can set it to auto-process every shot at capture — like mood.camera — or save the clean RAW/Log file and apply a stock later. Want to see what the same shot looks like on Portra 800 vs. Cinestill 800T? Tap the shot, pick the stock, done. No editor, no timeline, no export dialog. Trim a video clip if you need to. Save to camera roll. That's it.

The app keeps or discards the original RAW/Log file based on a single setting. You decide whether this is a film camera or a film processing lab.

**Starter stocks.** Kodak Portra 800, Kodak Gold 200, Cinestill 50D, Cinestill 800T, and a black-and-white stock for photo. Kodak 250D and 500T for video.

**Pricing.** $5/year or $10 lifetime. No subscription trap, no feature gating.

## What Makes This Different

**Post-capture emulation.** Most film camera apps lock you into a stock at the moment you shoot. This app doesn't. Shoot clean RAW or Apple Log 2, then apply any stock — or change your mind and swap it later. You get the commitment-free experimentation of digital with the look of film.

**Video, without the filmmaking baggage.** Film emulation apps overwhelmingly ignore video. The ones that do video are either pro filmmaking tools (Blackmagic) or full editing suites (Dehancer). This app treats video the same as photo: pick a stock, shoot, apply. Trim if needed. Done.

**Grain that's not an afterthought.** Grain isn't a slider that adds uniform noise. It's tied to the film stock's ISO, affects both size and amount, and uses an accurate pattern per stock. For video, the grain is temporally naturalistic — it moves like real film grain, not static overlay.

**Impulse-buy pricing.** $5/year or $10 lifetime. This isn't a SaaS play. It's priced to remove the friction between "curious" and "using it." Dehancer costs as much as a streaming subscription. This costs as much as a roll of Portra 800.

**No feature creep.** The app does one thing: make your shots look like film. It's not a social network, not a cloud sync service, not an AI prompt box. The differentiation is as much about what it refuses to become as what it builds.

## Who This Serves

Film enthusiasts who know what Portra 800 looks like and want that character in their pocket. They might shoot film already and want a digital complement, or they might love the film aesthetic without the cost and process of analog. They're on Instagram, they care about how their photos feel, and they don't want to spend 20 minutes grading a shot.

Secondarily: content creators and videographers who already use a Blackmagic + desktop LUT workflow and want something faster for quick-turnaround clips.

## Success Criteria

- **Personal benchmark**: The app replaces the creator's own Blackmagic Camera + desktop LUT video workflow for quick, everyday use.
- **App Store reception**: Positive ratings and steady download growth among film enthusiasts.
- **Quality bar**: Grain fidelity and film stock accuracy are good enough that users who know film say "yeah, that's Portra."

## Scope

**In for v1:**

- iOS (iPhone 12 Pro and newer for full RAW pipeline; older devices on JPEG fallback)
- Photo capture with manual shutter, ISO, and aperture (Pro models)
- Video capture with trim-only editing
- Auto-process or save-clean-and-apply-later modes
- Seven starter film stocks: Portra 800, Gold 200, Cinestill 50D, Cinestill 800T, B&W (photo); Kodak 250D, 500T (video)
- LUT → grain → halation → glow processing chain
- ISO-driven grain with stock-accurate patterns
- Keep/discard original RAW or Log toggle
- Save to camera roll
- $5/year or $10 lifetime pricing

**Explicitly out for v1:**

- Android
- Multi-clip video editing (combining, transitions, audio)
- Community preset sharing
- Importing RAW files from external cameras (DSLR/mirrorless)
- In-app sharing beyond saving to camera roll
- Custom LUT import
- Full editing suite or Lightroom-style adjustments

## Vision

If the app finds its audience, it becomes the default recommendation when someone asks "what's the best film camera app for iPhone?"

Android parity opens the other half of the mobile market. Community preset sharing lets users publish and remix their own film stocks. RAW import from DSLR and mirrorless cameras — saved to the iOS Photos library — turns the app into a lightweight film-look complement to any camera, not just the iPhone. But it never becomes a full editor. It stays simple. It stays fast. It stays $10.