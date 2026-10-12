# Mochi

A native macOS voice companion for conversation and speaking practice, powered by Codex Audio. Talk with Mochi in the language you choose, or in whatever language you speak. When you get stuck, find the words and practise saying them in your own voice. Each conversation can have its own character, instructions and language, and Mochi can sit on your desktop, a keyboard shortcut away from any app.

## Install

Requires **Apple Silicon and macOS 14 or later**.

```sh
brew install --cask xiaolai/tap/mochi
```

Or download the signed and notarized DMG from the [latest release](https://github.com/xiaolai/mochi-macOS/releases/latest) and drag Mochi into Applications.

To upgrade an existing Homebrew installation:

```sh
brew update
brew upgrade --cask xiaolai/tap/mochi
```

## Get started

1. Sign in through Codex on your Mac, then open Mochi.
2. In **Settings → General**, tell Mochi your name if you'd like her to use it, and choose the language new conversations start in.
3. Start a blank conversation with **New Conversation** (⌘N), or choose **New Conversation from Template…** (⇧⌘N).
4. Type a message, or click the microphone to speak and listen to the reply.
5. When you get stuck, use **Help Me Say This** (⇧⌘H): describe your thought in any language, get the words in the conversation's language, listen, and practise saying them.

## Languages

Every conversation has a language, set in **Conversation Instructions…** alongside its coaching style and speech speed:

- **A language to practise** — English, Chinese, Japanese, Korean, Spanish, French, German and more. Mochi speaks only that language, corrects it if you choose a coaching style, and Help Me Say This finds words in it.
- **Match Me** — Mochi replies in whatever language you speak and switches when you do. There is nothing to practise, so there are no corrections and no Help Me Say This.

New conversations start in the default language from **Settings → General**; changing it leaves existing conversations and templates as they are. Conversations from earlier versions of Mochi are English. Saved expressions remember their language, so practising one continues in it.

Mochi opens a voice conversation with a short spoken greeting in the conversation's language. A Match Me conversation hasn't heard you yet, so it greets you in the language of Mochi's interface.

## Characters and your name

**Your name.** Set it in **Settings → General**. Mochi uses it occasionally to address you; leave it empty and she uses no name.

**Mochi's name.** Each conversation can give its companion a different name: open **Conversation Instructions…** and enable **Use a custom character name**. An explicit character name takes precedence over names in the instructions. Future replies use it; saved messages keep their original speaker names, and changing the name does not regenerate old audio. A character name belongs to one conversation and can be saved in a template.

**Finding conversations.** The button above the conversation list sorts it by recent activity, date created, title or character name, and shows only the conversations with one character. Search matches titles, character names and messages.

## Desktop Mochi and shortcuts

Turn on **Show Mochi on the desktop** in **Settings → Desktop Mochi**, or press ⌃⌥⌘H. She sits in a small transparent window and follows the conversation: she listens while you record, thinks while a reply is prepared, talks while it plays, and breathes quietly while idle. Click her to start or finish a voice message, drag her anywhere, and Control-click her for more. Eyes that follow the pointer are an option, off by default; Reduce Motion keeps her still.

Two shortcuts work in every app, with no Accessibility permission:

| Shortcut | Action |
| --- | --- |
| ⌃⌥⌘M | **Talk to Mochi** — press once to start a voice message and again to send it, or hold it while you speak and let go to send |
| ⌃⌥⌘H | **Show or Hide Desktop Mochi** |

Change them in **Settings → General**. Mochi refuses a shortcut that macOS, its own menus or the other action already uses.

## Conversation templates

Mochi includes six built-in templates, all English practice:

| Template | Practice |
| --- | --- |
| Restaurant | Ordering meals and asking follow-up questions |
| Hotel check-in | Reservations, arrivals, and requests |
| Job interview | Explaining experience and answering questions |
| Vocabulary recall | Recalling a word list and using words in sentences |
| Pronunciation and shadowing | Listening, recording, and comparing selected sentences |
| Topic discussion | Exploring a topic at your own pace |

Open **New Conversation from Template…**, select a template, and customize its settings before starting. Supply your word list, target sentence, job, or topic when the companion asks for it. Starting a conversation does not start recording or playback.

Use **Manage Templates…** to create your own templates or duplicate a built-in. Each template can store a title, description, character name, instructions, language, coaching style, and optional speech speed. Built-ins are read-only.

A conversation's **Save as Template…** action saves its settings for reuse. Each new conversation receives a copy of the template settings; editing or deleting the source template leaves existing conversations intact. Vocabulary and shadowing templates guide practice; they do not provide spaced-repetition scheduling or validated pronunciation scores.

## Settings

| Tab | What it holds |
| --- | --- |
| General | Your name, the language for new conversations, the Codex connection, and keyboard shortcuts |
| Voices | Mochi's conversation voice and speed, and the voice of practice examples |
| Desktop Mochi | Showing Mochi on the desktop, and whether her eyes follow the pointer |
| Automation | Control by external assistants over MCP |
| Data & Privacy | Backups, the data folder, and what is sent where |

Mochi's menus, buttons and messages are available in English, Simplified Chinese, Traditional Chinese, Japanese and Korean, following your Mac's language. To choose a language for Mochi alone, open **System Settings → General → Language & Region → Applications**. The interface language is separate from the language of your conversations.

## Connect an external assistant with MCP

1. Keep Mochi running and open **Settings → Automation**.
2. Enable **Allow external assistants to control Mochi**.
3. Click **Copy MCP Configuration** and add it to your assistant's MCP settings.

A connected LLM can discover templates, create a setup for your goal, refine it, and start a conversation from it. Template tools are available only to external assistants; Mochi's voice tools do not manage templates.

| Tool | Purpose |
| --- | --- |
| `list_conversation_templates` | Discover built-in and user templates |
| `get_conversation_template` | Read instructions, settings, and the template revision |
| `create_conversation_template` | Create a user template |
| `update_conversation_template` | Patch selected settings using `expected_template_revision` |
| `delete_conversation_template` | Delete a user template using `expected_template_revision` |

For example, an assistant can create a template with these arguments:

```json
{
  "title": "Vocabulary with Loki",
  "character_name": "Loki",
  "instructions": "Ask me for a word list. Give one recall prompt at a time, let me answer before offering a hint, and ask me to use the word in a sentence.",
  "language": "ja",
  "coaching": "gentle"
}
```

`language` is a language code such as `en`, `zh`, `ja` or `es`, or `match` to reply in the user's language. Conversations, templates and `set_conversation_preferences` accept it, and `get_session` reports it.

Template updates preserve omitted fields. Creation requires a title and at least one effective setting: instructions, a character name, a language, coaching, or speech speed. Built-in templates must be duplicated to customize them.

To instantiate a template, read `get_session` and call `create_conversation` with `template_id` and the session's `revision` as `expected_revision`. Optionally supply `expected_template_revision` to reject a changed source. Template CRUD uses its own revisions and works independently of the open conversation.

External control is off by default. The local connection is restricted to your macOS user; recording always starts with you. A connected assistant can read active conversations and control supported actions, so enable access for assistants you intend to use.

## Data and backups

Conversations, templates, saved expressions, and practice recordings are stored locally. Conversation, transcription, and example-voice requests are processed by Codex.

Use **Export Library Backup…** to keep a portable copy of your library, and **Import Library Backup…** to restore or merge one.

Each save keeps the library as it was just before as `library.previous.json` in the data folder. If the library ever cannot be opened, **Settings → Data & Privacy** offers **Restore Earlier Copy**, which reinstates that copy and keeps the unreadable file beside it.

The library format is **version 3**. Before upgrading an older library, Mochi preserves its original bytes in a private `library-before-character-templates-v3*.json` backup. An app older than 0.4.0 cannot open a version 3 library; keep a full current export before downgrading. Mochi 0.6.4 and earlier open every conversation as English and drop a conversation's language when they save it.

Practice examples you saved with ElevenLabs before Mochi moved to Codex voices keep playing. A previously saved ElevenLabs key stays in your Keychain until you delete the `ELEVENLABS_API_KEY` item in Keychain Access.

## Build from source

With Xcode's command-line tools available:

```sh
swift test
python3 -m unittest discover -s scripts/tests
./scripts/build-app.sh
```

The development app and bundled MCP helper are built into `build/Mochi.app`. The release number lives only in `VERSION`. Distribution signing and notarization use `scripts/release.sh` with your Developer ID and notarytool Keychain profile.
