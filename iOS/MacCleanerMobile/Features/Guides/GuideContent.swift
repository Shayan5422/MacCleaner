import SwiftUI

/// The guides' text. Settings paths are those of iOS 18 and later (app settings moved to
/// Settings › Apps) with iOS 17's where they differ. Where a label changed between versions, the
/// step names both or says where to look.
enum GuideContent {
    private static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    private static let green = Color(red: 0.20, green: 0.74, blue: 0.36)
    private static let gray = Color(red: 0.50, green: 0.52, blue: 0.56)

    static let space: [Guide] = [
        Guide(
            id: GuideKey.photosRecentlyDeleted.rawValue,
            title: "Empty Recently Deleted in Photos",
            summary: "Photos you delete keep using space for 30 days.",
            symbol: "trash",
            category: .space,
            tint: MobileSection.photos.tint,
            why: "When you delete photos and videos, Photos keeps them in Recently Deleted for 30 days in case you change your mind. Until then, they still take up space.",
            benefit: "The space of everything you deleted in the last 30 days — often several gigabytes after a cleanup.",
            steps: [
                "Open **Photos**.",
                "Scroll down to **Utilities** and tap **Recently Deleted**. If you see tabs at the bottom, it's in **Collections**.",
                "Unlock it with Face ID, Touch ID or your passcode.",
                "Tap **Select**, then **Delete All** (it may be in the **•••** menu), and confirm.",
            ],
            iOS17Steps: [
                "Open **Photos** and tap **Albums**.",
                "Scroll down to **Utilities** and tap **Recently Deleted**.",
                "Unlock it with Face ID, Touch ID or your passcode.",
                "Tap **Select**, then **Delete All**, and confirm.",
            ],
            note: "This can't be undone. With iCloud Photos, the photos are removed from all your devices."
        ),
        Guide(
            id: GuideKey.filesRecentlyDeleted.rawValue,
            title: "Empty Recently Deleted in Files",
            summary: "Deleted files stay for 30 days and still use space.",
            symbol: "folder.badge.minus",
            category: .space,
            tint: MobileSection.files.tint,
            why: "Files you delete in the Files app, including the ones Mac Cleaner removed, wait in Recently Deleted for 30 days before iOS erases them.",
            benefit: "The space those files use: on your {device} for files stored on it, and in iCloud for iCloud Drive files.",
            steps: [
                "Open **Files** and tap **Browse**.",
                "Under **Locations**, tap **Recently Deleted**. If you don't see Locations, tap **Browse** again.",
                "Tap **Select** (it may be in the **•••** menu), then **Delete All**, and confirm.",
            ],
            note: "This can't be undone."
        ),
        Guide(
            id: GuideKey.optimizePhotos.rawValue,
            title: "Optimize photo storage",
            summary: "Keep full-size photos in iCloud and smaller copies here.",
            symbol: "icloud.and.arrow.up",
            category: .space,
            tint: Color(red: 0.20, green: 0.56, blue: 0.98),
            why: "With iCloud Photos, Optimize {device} Storage keeps the full-size originals in iCloud and space-saving versions on your {device}. Originals download when you open or share them.",
            benefit: "Often many gigabytes for large libraries. iCloud needs room for your whole library, which may mean a paid plan.",
            steps: [
                "Open **Settings › Apps › Photos**.",
                "Turn on **iCloud Photos** (it may be called **Sync this {device}**) if it's off.",
                "Choose **Optimize {device} Storage**.",
            ],
            iOS17Steps: [
                "Open **Settings › Photos**.",
                "Turn on **iCloud Photos** if it's off.",
                "Choose **Optimize {device} Storage**.",
            ],
            note: "Your {device} swaps in the smaller versions as it needs space, so the change can take a while to show."
        ),
        Guide(
            id: GuideKey.offloadApps.rawValue,
            title: "Offload unused apps",
            summary: "Remove apps you don't use but keep their data.",
            symbol: "arrow.down.app",
            category: .space,
            tint: Color(red: 0.11, green: 0.53, blue: 0.98),
            why: "When space runs low, iOS removes apps you haven't used in a while but keeps their documents and data. The icon stays on your Home Screen: tap it to download the app again.",
            benefit: "The size of each app you don't use. {device} Storage shows how much it would free.",
            steps: [
                "Open **Settings › Apps › App Store**.",
                "Turn on **Offload Unused Apps**.",
            ],
            iOS17Steps: [
                "Open **Settings › App Store**.",
                "Turn on **Offload Unused Apps**.",
            ],
            note: "To offload one app now, open **Settings › General › {device} Storage**, tap the app and choose **Offload App**."
        ),
        Guide(
            id: GuideKey.largestApps.rawValue,
            title: "Review your largest apps",
            summary: "See which apps use the most space, and why.",
            symbol: "chart.bar.xaxis",
            category: .space,
            tint: gray,
            why: "{device} Storage lists your apps by size and splits each one into the app itself and its documents and data, the part that keeps growing.",
            benefit: "It varies. Games, video and chat apps often hold several gigabytes of downloads and caches.",
            steps: [
                "Open **Settings › General › {device} Storage** and wait for the list to load.",
                "Apps are sorted by size. Tap one to see its **App Size** and **Documents & Data**.",
                "Tap **Offload App** to remove the app but keep its data, or **Delete App** to remove both.",
                "For large documents and data, look in the app's own settings for a way to clear downloads or its cache.",
            ]
        ),
        Guide(
            id: GuideKey.messagesHistory.rawValue,
            title: "Keep messages for 30 days or 1 year",
            summary: "Delete old messages and attachments automatically.",
            symbol: "message",
            category: .space,
            tint: green,
            why: "Messages keeps every conversation forever unless you change it. Years of photos, videos and voice messages add up.",
            benefit: "Up to several gigabytes on an {device} with years of messages.",
            steps: [
                "Open **Settings › Apps › Messages**.",
                "Under **Message History**, tap **Keep Messages**.",
                "Choose **30 Days** or **1 Year**, then tap **Delete** to confirm.",
            ],
            iOS17Steps: [
                "Open **Settings › Messages**.",
                "Under **Message History**, tap **Keep Messages**.",
                "Choose **30 Days** or **1 Year**, then tap **Delete** to confirm.",
            ],
            note: "Older messages and their attachments are deleted for good. With Messages in iCloud, they're deleted on your other devices too."
        ),
        Guide(
            id: GuideKey.messagesAttachments.rawValue,
            title: "Review large attachments in Messages",
            summary: "Find and delete the biggest videos and files in your chats.",
            symbol: "paperclip",
            category: .space,
            tint: green,
            why: "Videos and files people send you stay in Messages until you delete them. {device} Storage lists them from largest to smallest.",
            benefit: "Often hundreds of megabytes, sometimes a few gigabytes.",
            steps: [
                "Open **Settings › General › {device} Storage** and tap **Messages**.",
                "Tap **Review Large Attachments**.",
                "Swipe left on an attachment and tap **Delete**, or tap **Edit** to select several.",
            ],
            note: "In a conversation, you can also tap the name at the top to see its photos, links and files."
        ),
        Guide(
            id: GuideKey.safariHistory.rawValue,
            title: "Clear Safari history and website data",
            summary: "Remove history, cookies and cached website data.",
            symbol: "clock.arrow.circlepath",
            category: .space,
            tint: blue,
            why: "Safari keeps your history and data from the sites you visit: cookies, caches and offline files. Clearing them frees space and removes data that sites use to recognize you.",
            benefit: "Usually tens to hundreds of megabytes. You'll be signed out of websites.",
            steps: [
                "Open **Settings › Apps › Safari**.",
                "Tap **Clear History and Website Data**.",
                "Choose how far back to clear, for example **All History**, then tap **Clear History**.",
            ],
            iOS17Steps: [
                "Open **Settings › Safari**.",
                "Tap **Clear History and Website Data**.",
                "Choose how far back to clear, for example **All History**, then tap **Clear History**.",
            ],
            note: "To remove the data of some sites only, open **Advanced › Website Data** in Safari's settings."
        ),
        Guide(
            id: GuideKey.safariTabs.rawValue,
            title: "Close Safari tabs automatically",
            summary: "Stop old tabs from piling up.",
            symbol: "square.on.square",
            category: .space,
            tint: blue,
            why: "Safari keeps every tab until you close it. Hundreds of old tabs take up storage and make Safari slower to start.",
            benefit: "A faster, tidier Safari. The space saved is usually small.",
            steps: [
                "Open **Settings › Apps › Safari**.",
                "Under **Tabs**, tap **Close Tabs**.",
                "Choose **After One Day**, **After One Week** or **After One Month**.",
            ],
            iOS17Steps: [
                "Open **Settings › Safari**.",
                "Under **Tabs**, tap **Close Tabs**.",
                "Choose **After One Day**, **After One Week** or **After One Month**.",
            ],
            note: "To close every tab now, touch and hold the tabs button in Safari and choose **Close All Tabs**."
        ),
        Guide(
            id: GuideKey.downloadedMedia.rawValue,
            title: "Remove downloaded music, podcasts and TV",
            summary: "Delete downloads you've already played or watched.",
            symbol: "arrow.down.circle",
            category: .space,
            tint: Color(red: 0.98, green: 0.24, blue: 0.36),
            why: "Downloaded songs, podcast episodes, movies and TV episodes stay on your {device} until you remove them, even after you've played them.",
            benefit: "Often several gigabytes, especially for downloaded movies and TV shows.",
            steps: [
                "Open **Settings › General › {device} Storage**.",
                "Tap **Music**, **Podcasts** or **TV**.",
                "Swipe left on what you don't need and tap **Delete**, or tap **Edit** to remove several.",
                "To keep it tidy, turn on **Optimize Storage** in **Settings › Apps › Music**, and have played episodes removed in **Settings › Apps › Podcasts**.",
            ],
            iOS17Steps: [
                "Open **Settings › General › {device} Storage**.",
                "Tap **Music**, **Podcasts** or **TV**.",
                "Swipe left on what you don't need and tap **Delete**, or tap **Edit** to remove several.",
                "To keep it tidy, turn on **Optimize Storage** in **Settings › Music**, and **Remove Played Downloads** in **Settings › Podcasts**.",
            ]
        ),
        Guide(
            id: GuideKey.chatAppMedia.rawValue,
            title: "Clear WhatsApp and Telegram media",
            summary: "Chat apps keep every photo and video you receive.",
            symbol: "bubble.left.and.bubble.right",
            category: .space,
            tint: Color(red: 0.12, green: 0.68, blue: 0.60),
            why: "WhatsApp and Telegram keep the media from all your chats inside the app. iOS doesn't let other apps clear it, but both apps have their own storage tools.",
            benefit: "Often the biggest app data on an {device}: several gigabytes is common.",
            steps: [
                "**WhatsApp**: open its **Settings › Storage and Data › Manage Storage** and review the largest files and chats.",
                "To stop WhatsApp from saving every photo to your library, turn off **Save to Photos** in its **Settings › Chats**.",
                "**Telegram**: open its **Settings › Data and Storage › Storage Usage** and clear the cache.",
                "In the same place, choose how long Telegram keeps media, for example **1 week**.",
            ],
            note: "These menus change between app versions. If you can't find them, search the app's settings for “storage”."
        ),
    ]

    static let security: [Guide] = [
        Guide(
            id: GuideKey.updateSystem.rawValue,
            title: "Update iOS",
            summary: "Install the latest security fixes.",
            symbol: "arrow.triangle.2.circlepath",
            category: .security,
            tint: gray,
            why: "Updates fix security flaws that attackers use, sometimes ones already being exploited. Apple lists what each update fixes on its security releases page.",
            benefit: "Your {device} against known attacks on {system}, Safari and Apple's apps.",
            steps: [
                "Open **Settings › General › Software Update**.",
                "If an update is listed, tap **Update Now** or **Install Now**. Your {device} restarts to finish.",
                "Tap **Automatic Updates** and turn everything on, so security fixes install without waiting for you.",
            ],
            note: "Plug in or charge to at least 50%, and use Wi-Fi. Back up first if you haven't recently."
        ),
        Guide(
            id: GuideKey.passcode.rawValue,
            title: "Set a passcode and Face ID",
            summary: "Lock your device and encrypt your data.",
            symbol: "lock",
            category: .security,
            tint: green,
            why: "A passcode turns on the encryption that protects your data if your {device} is lost or stolen. Face ID or Touch ID makes a long passcode easy to live with.",
            benefit: "Everything on your {device}. Apple Pay and Stolen Device Protection need a passcode too.",
            steps: [
                "Open **Settings › Face ID & Passcode** (or **Touch ID & Passcode**).",
                "Tap **Turn Passcode On** and enter a 6-digit code, or tap **Passcode Options** for a longer one.",
                "Tap **Set Up Face ID** (or **Add a Fingerprint**) and follow the steps.",
            ],
            note: "Avoid easy codes like 123456 or your birthday."
        ),
        Guide(
            id: GuideKey.stolenDeviceProtection.rawValue,
            title: "Turn on Stolen Device Protection",
            summary: "Stop a thief who knows your passcode from taking over.",
            symbol: "lock.shield",
            category: .security,
            tint: MobileSection.protection.tint,
            why: "If someone watches you type your passcode and then steals your iPhone, they could change your Apple Account password and turn off Find My. With Stolen Device Protection, away from familiar places these changes need Face ID or Touch ID and an hour's wait.",
            benefit: "Your Apple Account, saved passwords and payment cards, even if someone learns your passcode.",
            steps: [
                "Open **Settings › Face ID & Passcode** (or **Touch ID & Passcode**) and enter your passcode.",
                "Scroll to **Stolen Device Protection** and tap **Turn On Protection**.",
                "For the strongest protection, tap **Require Security Delay** and choose **Always**.",
            ],
            iOS17Steps: [
                "Make sure you have iOS 17.3 or later: **Settings › General › Software Update**.",
                "Open **Settings › Face ID & Passcode** (or **Touch ID & Passcode**) and enter your passcode.",
                "Scroll to **Stolen Device Protection** and tap **Turn On Protection**.",
                "For the strongest protection, tap **Require Security Delay** and choose **Always** (iOS 17.4 and later).",
            ],
            note: "It needs a passcode, Face ID or Touch ID, two-factor authentication for your Apple Account, Find My and Significant Locations. Apps can't check whether it's on.",
            iPhoneOnly: true
        ),
        Guide(
            id: GuideKey.safariProtection.rawValue,
            title: "Turn on Safari protection",
            summary: "Block sites that spread malware in Safari.",
            symbol: "safari",
            category: .security,
            tint: MobileSection.protection.tint,
            why: "Mac Cleaner Protection is a Safari content blocker. It uses abuse.ch's URLhaus and ThreatFox lists to stop Safari from loading sites known to spread or control malware.",
            benefit: "Safari, and pages apps open with Safari, against the sites on those lists. It can't block every bad site, and it doesn't work in other browsers.",
            steps: [
                "Open **Settings › Apps › Safari › Extensions**.",
                "Tap **Mac Cleaner Protection** and turn on **Allow Extension**.",
                "Come back to Mac Cleaner so it can download the latest lists.",
            ],
            iOS17Steps: [
                "Open **Settings › Safari › Extensions**.",
                "Tap **Mac Cleaner Protection** and turn on **Allow Extension**.",
                "Come back to Mac Cleaner so it can download the latest lists.",
            ],
            note: "The lists update while Mac Cleaner is open, at most every 12 hours. Content blockers can't see the pages you visit, so Mac Cleaner never learns them."
        ),
        Guide(
            id: GuideKey.privacyAccess.rawValue,
            title: "Check which apps see Photos and Contacts",
            summary: "Make sure only apps you trust have full access.",
            symbol: "hand.raised",
            category: .security,
            tint: Color(red: 0.25, green: 0.47, blue: 0.98),
            why: "Apps you allowed long ago may still see your whole photo library or all your contacts. Limited access lets an app see only what you pick.",
            benefit: "Your photos, the places they were taken, and your contacts' details.",
            steps: [
                "Open **Settings › Privacy & Security › Photos**.",
                "Tap each app and choose **Limited Access**, **Add Photos Only** or **None** if it doesn't need everything.",
                "Go back to **Privacy & Security**, tap **Contacts** and do the same.",
                "For a review of everything you share, open **Safety Check** in **Privacy & Security**.",
            ],
            iOS17Steps: [
                "Open **Settings › Privacy & Security › Photos**.",
                "Tap each app and choose **Selected Photos**, **Add Photos Only** or **None** if it doesn't need everything.",
                "Go back to **Privacy & Security**, tap **Contacts** and turn off apps that don't need them.",
                "For a review of everything you share, open **Safety Check** in **Privacy & Security**.",
            ],
            opensAppSettings: true
        ),
        Guide(
            id: GuideKey.profiles.rawValue,
            title: "Check VPN & Device Management",
            summary: "Look for profiles and VPNs you don't recognize.",
            symbol: "network",
            category: .security,
            tint: Color(red: 0.36, green: 0.40, blue: 0.92),
            why: "Configuration profiles can add VPNs, certificates and device management that let someone else see or control your traffic. Profiles from your work or school are normal; ones you don't recognize aren't.",
            benefit: "Your web traffic and the settings an organization could control.",
            steps: [
                "Open **Settings › General › VPN & Device Management**.",
                "Look at the VPN and every profile listed.",
                "If you don't recognize a profile, tap it, then **Remove Profile**. If it's from your work or school, ask them first.",
                "For a VPN you don't use, tap **VPN**, tap ⓘ next to it, then **Delete VPN**.",
            ],
            note: "If only VPN is listed, no profile is installed."
        ),
        Guide(
            id: GuideKey.lockdownMode.rawValue,
            title: "Consider Lockdown Mode",
            summary: "Extreme protection for people at risk of targeted attacks.",
            symbol: "exclamationmark.shield",
            category: .security,
            tint: Color(red: 0.30, green: 0.32, blue: 0.80),
            why: "Lockdown Mode is for the few people who may be targeted by sophisticated spyware, such as journalists and activists. It turns off features attackers often use, like some message attachments and web technologies.",
            benefit: "Your {device} against rare, highly targeted attacks. Some apps, websites and features work differently while it's on.",
            steps: [
                "Open **Settings › Privacy & Security**.",
                "Scroll down to **Lockdown Mode** and tap **Turn On Lockdown Mode**.",
                "Tap **Turn On & Restart** and enter your passcode.",
            ],
            note: "Most people don't need it. Apps can't check whether it's on."
        ),
    ]
}
