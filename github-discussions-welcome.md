## Welcome to Nextcloud Update Manager Discussions 👋

This tool started as a personal solution for managing multiple Nextcloud installations on ISPConfig servers — and apparently that's a problem more people have than I thought.

If you're running Nextcloud on ISPConfig and tired of logging into every server individually to check for updates, you're in the right place.

---

### What this space is for

**🐛 Something not working?**
Before opening an issue, feel free to describe your problem here first. Especially useful if you're not sure whether it's a bug or a configuration problem. Include your Nextcloud version, PHP version, and ISPConfig setup — that usually helps narrow things down fast.

**🔧 ISPConfig setups vary**
Directory structures, PHP versions, sudo configurations — ISPConfig can be set up in many different ways. If the scripts don't work out of the box for your setup, share what's different. Chances are others have the same configuration.

**💡 Ideas and feature requests**
Something missing? Thinking about an edge case that isn't handled? Open a discussion before filing a feature request — a quick exchange often clarifies whether it makes sense and how it fits.

**📦 Apps flagged as unknown?**
Nextcloud regularly integrates third-party apps into its server package. If you see an app listed as *"not found in App Store"* that you know ships with Nextcloud, post it here and it'll get added to the bundled apps list.

**🖥️ Share your setup**
Running this on a specific ISPConfig version or Debian/Ubuntu release? Have a custom configuration that works well? Others can learn from it — share what you've got.

---

### A few things worth knowing

- These scripts are built for **ISPConfig** specifically. They won't work on plain LAMP stacks or other control panels without modification.
- Tested on **Debian 11, 12, and 13** — if you're running something else and it works (or doesn't), let me know.
- The `CORE_APPS_PATTERN` list in the scripts will occasionally need updating as Nextcloud integrates more apps. Community reports are the only practical way to keep it current.

---

Looking forward to hearing how it works (or doesn't) in your environment.
