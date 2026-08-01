# Kehai

A faster way to switch apps and find windows.

## Download

[Download Kehai 0.3.8 for Apple Silicon](https://github.com/littlebobert/kehai/releases/download/0.3.8/Kehai-0.3.8-mac.zip)

## Build and run

```bash
./Scripts/reset-build-run.sh
```

## Required permissions

- **Screen & System Audio Recording** — shows window thumbnails.
- **Accessibility** — opens the selected window.
- **Automation → Safari** *(optional)* — shows and activates individual Safari tabs.

An OpenAI or Anthropic API key is required to generate task groups.

## Known limitations

- DRM, secure, and protected windows can appear blank.
- macOS can prevent a third-party utility from crossing some full-screen or Space boundaries perfectly.

## License

Kehai is open source under the [MIT License](LICENSE). Copyright © 2026 Justin Garcia.
