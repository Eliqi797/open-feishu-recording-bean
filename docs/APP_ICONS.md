# Open 飞书录音豆 app icons

Generated with the built-in image_gen tool. The project author supplied a reference image of the compatible circular recorder and requested the strap, white and black device variants. White is the bundled default. The original advertisement image is not distributed here. These are unofficial app icons; product names and trademarks remain with their respective owners. See [third-party notices](../THIRD_PARTY_NOTICES.md).

Assets:
- `harmony/resources/base/media/recordingbean_white.png`
- `harmony/resources/base/media/recordingbean_black.png`
- `ios/RecordingBeanApp/Assets.xcassets/AppIcon.appiconset/recordingbean-white.png`
- `ios/RecordingBeanApp/Assets.xcassets/AppIconBlack.appiconset/recordingbean-black.png`

## iOS app icon

The iOS Xcode target uses `AppIcon` as its primary icon and `AppIconBlack` as an alternate icon. Both are 1024×1024 exports of the previously approved transparent device artwork; the strap and recorder design were not redrawn. The asset catalog is included in the target's Resources phase, and both Debug and Release configurations include `AppIconBlack` as an alternate icon. In the app, open 设置 → 外观与图标 to choose white or black; iOS displays its own confirmation when the icon changes. These transparent assets are verified for the current personal-use device installation, not for App Store submission.

On 2026-09-27 the rebuilt app was installed on iPhone 14 Pro Max. The white icon appeared on the Home Screen; switching to black and back to white each produced the iOS success prompt. The final selection was restored to white.

## White generation prompt

Use case: logo-brand. Make one clean square app icon based on the actual recorder shown in this reference photograph. The user explicitly requires KEEPING THE TOP FABRIC STRAP. Extract the product identity, not the advertisement. Icon composition: a silver-white near-circular pebble recorder centered horizontally, its round body about 60% of canvas width and positioned slightly below center. A SHORT VERTICAL WHITE FABRIC HANGING STRAP emerges behind the TOP of the circle, exactly like the broad white rectangular strap in the reference; show its squared softly rounded top and width around one-third of the circle's width. Strap plus circle should comfortably fit within the central 76% of the square height. Strap is essential and clearly visible. Device face: two small oval microphone grilles at top and bottom, tiny orange indicator dot below the top grille, subtle right side button. Simplified tasteful app icon, minimal detail, smooth silver-white surfaces, restrained edge shading only. Full-bleed SOLID DEEP TEAL background #077568, opaque including all four corners. Single front-facing object. No text, no logo, no Feishu brand mark, no phone, no advertising, no charts, no extra decorations, no dramatic shadows or glow. Readable at small size. Actual final icon art, not a mockup or contact sheet. Normal opaque PNG.

## Black edit prompt

Use case: precise-object-edit. This is an edit of the supplied finished app icon. Create the BLACK device color variant. Change ONLY the silver-white circular recorder body, small side button, and white fabric hanging strap to deep charcoal black with subtle graphite edge highlights. Retain exact same round silhouette, size, composition, top strap shape and length, two microphone grilles, tiny orange indicator light, and unchanged teal background. Keep strap visible, black fabric. Grilles should remain legible using restrained slightly lighter dark-gray housing and black holes. Simple and premium, no added detail, no text, no logo. Do not move, resize or redesign anything. Keep ordinary opaque square PNG, background extends to all corners.

## Final transparent assets

Both final assets have genuine RGBA transparency; the green background was removed using the built-in image tool at the user's request. These supersede the opaque green versions. PNG dimensions are 1254 x 1254 and corner alpha is zero.

Final extraction prompt (applied separately to both variants):

Use case: background-extraction. Edit the supplied finished app icon. Remove ONLY the entire green/teal backdrop and replace it with genuine alpha transparency. Preserve the recorder and fabric hanging strap exactly, including device color, all shape, size, position, material, microphone grilles, orange indicator, and side button. Keep the same square canvas and padding. Foreground must stay solid and opaque. Clean precise edges with no green fringe. No cast shadow outside the object. Output transparent PNG RGBA with alpha zero outside the object. DO NOT render checkerboard squares or a white/black/color background; actual transparency is required. No design changes.

## Dynamic launcher icons

Huawei requires a formally released app, icon-management service activation, and reviewed icons. In AGC configure the reviewed black icon with ID `recordingbean_black` (optional white dynamic version `recordingbean_white`). The app queries `appInfoManager.queryDynamicIcons`, selects the black ID only when it is returned, and uses `disableDynamicIcon` for the bundled white default. Settings report unavailable or errors instead of claiming local image previews changed the launcher. No registration, publication or review has been performed by this task.

Official docs: https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/appgallery-appinfo-manage

## Device verification — 2026-09-25 21:03

Offline signed build succeeded and was installed on the connected phone. Settings > 应用图标 shows both transparent variants with no green backdrop. AppGallery query returned the no-dynamic-data branch; black switching stays unavailable rather than falsely claiming success. The launcher displays the new white recorder and strap over the system's translucent icon treatment, with no green background. Launching the installed app through HDC succeeded; a subsequent launcher tap was not verified because the target was no longer visible. Existing provider settings were not changed.

Private device-test screenshots and logs are not distributed in this repository.
