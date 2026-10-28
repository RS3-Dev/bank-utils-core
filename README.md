# Bank Core

Bank Core lets RuneScape bank plugins share one sidebar and display their own
arrangements of your bank items. Bank Tags, Bank Cleaner, Advanced Bank Search
and War Chest provide the features; Core supplies the bank window space and
handles the real items behind their pages.

## Install

Enable **PrettyUI**, **Bank Core**, and the bank feature plugins you want in your
client's plugin manager. Core by itself provides no tags, categories or searches.

For a manual installation, create a `bankcore` folder in your client's development
plugins directory. Copy `main.lua`, `plugin.json`, `LICENSE` and `lib/` from this
repository into it, or extract the `bankcore` folder from a runtime release ZIP:

```text
plugins/
  bankcore/
    main.lua
    plugin.json
    LICENSE
    lib/
```

Install PrettyUI separately. No build step is needed. The docs and examples are
for reference and do not need to go in your Core plugin folder.

## Use it

1. Open your bank and select **All Items**.
2. Click a plugin's icon on the left rail. Hover an icon to see its name.
3. Choose a tag, category or search result in that plugin's sidebar.
4. Use the displayed items with the bank's normal clicks and menus.
5. Click a native bank tab to return to the normal bank view.

A plugin with no sidebar column can open its page directly from its rail icon.
Drag an icon up or down the rail to change the order; Core remembers it, and
dragging does not switch the plugin or page you are using.

These pages rearrange the view of your items; they do not create items or add
bank storage. Repeated item pictures do not duplicate an item in your bank. When
a page lists an item that stacks in the bank more than once, every picture shows
your one stack of it and works with it. Items that never stack, such as augmented
gear, are separate stacks: each picture uses the next one, and a picture with no
stack left shows zero.

## Settings and troubleshooting

Core's plugin panel has one setting: **Enable debug**. It writes diagnostics to
the client log for troubleshooting; leave it off during normal play. Feature
plugins have their own settings. Banking Tweaks supplies modifier-click options.

- **No sidebar:** check that PrettyUI and Core are enabled, then reopen the bank.
- **No feature icons:** check that the feature plugins and their dependencies loaded.
- **A page will not open:** select the bank's native All Items tab and try again.
- **A problem after reloading:** reload Core, then the affected feature plugin.
  Keep your saved plugin data while investigating.

Closing the bank or disabling Core removes its controls and restores the bank
window. A client component that no longer accepts changes can delay restoration;
the [known limitations](docs/API.md#known-limitations) describe that case.

## Develop a bank plugin

- [API reference](docs/API.md): register a sidebar, supply an item page or draw a custom
  view, and read menus.
- [Examples](examples/README.md): a standard page, sidebar controls and a custom page.
- [Contributing](CONTRIBUTING.md): guidelines for changes and pull requests.

Core requires no HTTP permission and sends no network requests. Check input and
appearance in RuneScape when changing those parts.

## License

Copyright (C) 2026 Bank Core contributors. Core and its examples are licensed
under the [GNU General Public License, version 3 only](LICENSE)
(`GPL-3.0-only`). Include the license when redistributing them.
