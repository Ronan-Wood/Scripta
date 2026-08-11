import AppKit

/// The standard main menu a normal app carries. LSUIElement apps start with none — which
/// silently breaks ⌘C/⌘V/⌘Z in every text field — so this is both the "normal app" chrome
/// and the fix for edit shortcuts. Built in code (no nib); standard selectors dispatch
/// through the responder chain.
enum MainMenu {
    static func install(settingsTarget: AnyObject, settingsAction: Selector,
                        helpAction: Selector) {
        let main = NSMenu()

        // App menu (title is replaced by the app name automatically).
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Scripta",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Scripta", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Scripta",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Scripta"))

        // File
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, title: "File"))

        // Edit — the one that makes ⌘C/⌘V/⌘Z work everywhere.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu, title: "Edit"))

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        // Help — where the Docs section went (Doc 4 §2). It was a sidebar row competing with the
        // four surfaces a reader actually works in; documentation is what this menu is for, and
        // `NSApp.helpMenu` is what puts it in the place macOS has already taught everyone to look.
        let helpMenu = NSMenu(title: "Help")
        let help = NSMenuItem(title: "Scripta Help", action: helpAction, keyEquivalent: "?")
        help.target = settingsTarget
        helpMenu.addItem(help)
        main.addItem(submenu(helpMenu, title: "Help"))
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
