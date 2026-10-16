# org-browser-run

Run one org-mode heading as a task in your own, already-open browser tab.

You keep a review file in org-mode: one heading per reply to a reviewer's comment, or per text edit to a shared
document. You put point on a heading and press a key. A headless [Claude Code](https://claude.com/claude-code) agent
connects to your browser through [chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp), finds
the document tab, and does that one task there: it types the reply into the comment thread, or fills Find and Replace
with the edit. You watch the browser and decide what to keep. The outcome is written back into the heading.

```
Emacs (heading at point) ──claude -p──▶ agent (agent-prompt.md)
                                         └─ chrome-devtools-mcp --browserUrl=http://127.0.0.1:9222
                                              └─ your Chrome/Chromium, dedicated profile, open tab
result STATUS/TAB/DETAIL ──▶ :BROWSER_STATUS: / :BROWSER_RUN: + :BROWSER_LOG: drawer in the heading
```

The agent's only tools are the browser tools. It cannot run shell commands, edit local files or browse the web, and its
instructions forbid opening new tabs, navigating away, changing sharing settings, uploading files and «Replace all».

## When to use it, and when not to

There are two ways to deliver changes to a document that lives on Google Drive.

**1. Upload the file itself.** You own the document, nobody else is editing or commenting on it, and you have the
current version locally (a `.docx`, a PDF, an export of your org file). Make the changes locally and upload the new
version to Drive (*File → Manage versions → Upload new version*, or replace the file). This is faster and fully
reproducible. org-browser-run is not needed and cannot do this: file uploads are outside what the agent is allowed to
do.

**2. Work inside the live document with this agent.** The document is shared and alive: a customer or colleague owns
it, other people edit it at the same time, and the review happens in comment threads. Re-uploading the file would
break this:

- comment threads and their anchors are lost or detached when the content is replaced;
- edits made by others since your copy was taken are overwritten;
- the version history no longer shows *what* changed, only that the whole file was replaced;
- you may not have permission to upload a new version at all, only to comment or suggest.

In this case each change has to be made in place, by hand: find the thread, paste the reply, find the sentence, change
it. org-browser-run does exactly that hand work, one heading at a time, while you stay in control:

- replies to existing comment threads (the text is pasted verbatim from the heading);
- text edits given as «Шукати / Було / Стало» (find / was / becomes), applied through Find and Replace on a single
  match.

A rule of thumb: if the document has comments you must answer, or other people edit it, use the agent. If it is your
own file and nobody has touched it, upload it.

## Requirements

- Emacs 29+ with org-mode.
- [Claude Code](https://claude.com/claude-code) CLI (`claude`) logged in.
- Node.js with `npx` (chrome-devtools-mcp is started with `npx -y chrome-devtools-mcp@latest`).
- Google Chrome, Chromium or another Chromium-based browser.

## Installation

```elisp
(load "~/path/to/org-browser-run/org-browser-run.el")
(setq org-browser-run-dir "~/path/to/org-browser-run/"
      org-browser-run-chrome-program "google-chrome-stable" ; or "chromium"
      org-browser-run-model "sonnet")
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c n c") #'org-browser-run-start-chrome)
  (define-key org-mode-map (kbd "C-c n l") #'org-browser-run-locate)
  (define-key org-mode-map (kbd "C-c n s") #'org-browser-run-stage)
  (define-key org-mode-map (kbd "C-c n S") #'org-browser-run-submit)
  (define-key org-mode-map (kbd "C-c n k") #'org-browser-run-kill))
```

## Setup (once)

1. `C-c n c` (`org-browser-run-start-chrome`) starts the browser with `--remote-debugging-port=9222` and a dedicated
   profile in `~/.cache/org-browser-run/profile`. Chrome 136+ refuses remote debugging on the default profile, so this
   profile is separate from your everyday one.
2. Log into Google in that browser window once. The profile keeps the session.
3. Open the document you are going to work on in a tab.

## Preparing the org file

Point the file at the document; every heading inherits the property:

```org
#+PROPERTY: BROWSER_URL https://docs.google.com/document/d/<DOCUMENT-ID>/edit
```

Press `C-c C-c` on that line to reload it. The agent picks the open tab whose URL contains the document ID.

A reply to a comment thread:

```org
* TODO C05 · reply to the comment on section 3.2
  :PROPERTIES:
  :ДЕ:       section 3.2, шукати «retention period»
  :BROWSER_LOCATOR: Please clarify the retention period for audit logs
  :END:
#+begin_example
The retention period for audit logs is 12 months; see section 3.2.4.
#+end_example
```

A text edit:

```org
* TODO E02 · retention period
Шукати:
#+begin_example
are kept for 6 months
#+end_example
Було:
#+begin_example
Audit logs are kept for 6 months.
#+end_example
Стало:
#+begin_example
are kept for 12 months
#+end_example
```

Properties the agent understands:

| Property            | Meaning                                                                                       |
|---------------------|-----------------------------------------------------------------------------------------------|
| `BROWSER_URL`       | Document URL; usually set once with `#+PROPERTY:`.                                            |
| `BROWSER_LOCATOR`   | Primary key for finding the place: a verbatim quote of the comment, or the exact text to edit. |
| `BROWSER_NOTE`      | Extra instruction for this run, e.g. «variant 2» or «the thread where Anna replied».           |
| `ДЕ` / `РОЗДІЛ`     | Where in the document (section, anchor quote, comment number).                                |

One `#+begin_example` block is one paragraph and is pasted verbatim. A heading with the `CUSTOM_ID` `howto` (see
`org-browser-run-context-ids`) is sent to the agent with every run as general context.

### Evidence references

Review items usually cite their evidence: code lines, a text extraction of another document. Write them as org links,
so they open with `C-c C-o` (or a click) and export as real links:

- **A line is an org link with a line number and a short label:**
  `[[file:refs/ksk-bz/addons/kms/services.py::95][kms/services.py:L95]]`. A number after `::` is an exact line number
  (text after `::` would be a content search, so always write the number). One link per line; a range is the first
  line plus its end, `[[file:refs/x/models/users.py::152][models/users.py:L152]]–154`; a list is several links. Bare
  forms like `x.py:152`, `x.py:152-154` or a continuation `:186` are not clickable.
- **The label** is the last two path components plus `:LNN` (`all/values.yaml:L171`), enough to tell same-named files
  apart while keeping the line short.
- **Paths are relative to the org file's folder.** Sources outside the project go into a `refs/` folder next to the org
  file, as symlinks to the checkouts: `refs/btz-deployment -> /abs/path/to/btz-deployment/`. The links then work
  wherever the review folder sits, and the review never copies code.
- **Documents cited by line** (a `.docx` specification, a deployment guide) are converted once to text in `refs/`
  (`pandoc -t plain --wrap=none guide.docx -o refs/guide.txt`), so the line numbers stay fixed.
- **A file or directory without a line** is a plain org link: `[[file:refs/ksk-ki/scripts/]]`.
- **Pin the version.** Line numbers are only true for one commit. Name the commit of each `refs/` repo in the `howto`
  section, and check every link against it before handing the file over.

Hyperbole's `"path:LNN"` form is for places without org links (code comments, Markdown, chat); in org files use the
links above.

## Usage

| Key       | Command                         | What happens                                                                     |
|-----------|---------------------------------|----------------------------------------------------------------------------------|
| `C-c n l` | `org-browser-run-locate`        | Only finds the place: opens the thread or highlights the text. Types nothing.    |
| `C-c n s` | `org-browser-run-stage`         | Prepares the action and stops before the final click.                            |
| `C-c n S` | `org-browser-run-submit`        | Same, plus the final click and a check; asks first; marks the heading `DONE`.    |
| `C-c n k` | `org-browser-run-kill`          | Stops the running agent.                                                         |
| `C-c n c` | `org-browser-run-start-chrome`  | Starts the controlled browser.                                                   |

The recommended loop for each heading:

1. `C-c n s` (stage). The reply is typed but not sent; or Find and Replace is filled with the match highlighted.
2. Check it in the browser. Click «Reply» / «Replace» yourself, or run `C-c n S` to let the agent do it.
3. A successful submit run (`STATUS: submitted`) marks the heading `DONE` (the buffer's first done keyword; see
   `org-browser-run-done-state`). If you clicked in the browser yourself after a stage run, mark it `DONE` by hand.
   Stage, locate and failed runs never change the TODO state.

Progress streams into the `*org-browser-run*` buffer. When the run ends, the heading gets:

```org
:BROWSER_STATUS: staged
:BROWSER_RUN: [2026-10-14 Wed 11:20]
:BROWSER_LOG:
- [2026-10-14 Wed 11:20] stage staged — Відповідь введено, не надіслано. Тред знайдено за locator.
  Вкладка: Requirements — https://docs.google.com/document/d/…/edit
:END:
```

Statuses: `located`, `staged`, `submitted`, `not-found`, `ambiguous`, `not-actionable`, `error`. On `not-found` or
`ambiguous`, improve `:BROWSER_LOCATOR:` or add a `:BROWSER_NOTE:` and run again. Previous runs in `:BROWSER_LOG:` are
read by the agent, so it does not repeat an action that was already submitted.

## Safety

- Only one run at a time; one heading, one action.
- Headings not in `org-browser-run-allowed-states` (default `TODO`) ask before running.
- Example blocks longer than the Google Docs comment limit (2048 UTF-8 bytes, about 1100 Cyrillic characters) are
  flagged before the run.
- Start with `locate` and `stage` on a new document. Use `submit` once the locators work.

## Customization

| Variable                          | Default                              |
|-----------------------------------|--------------------------------------|
| `org-browser-run-claude-program`  | `"claude"`                           |
| `org-browser-run-model`           | `"sonnet"`                           |
| `org-browser-run-chrome-program`  | `"chromium"`                         |
| `org-browser-run-debug-port`      | `9222`                               |
| `org-browser-run-profile-dir`     | `"~/.cache/org-browser-run/profile"` |
| `org-browser-run-allowed-states`  | `("TODO")`                           |
| `org-browser-run-context-ids`     | `("howto")`                          |
| `org-browser-run-comment-limit`   | `2048`                               |
| `org-browser-run-done-state`      | `t` (first done keyword; `nil` off)  |

To teach the agent new task kinds or another web editor, edit [agent-prompt.md](agent-prompt.md). No Elisp changes are
needed; the prompt is read on every run.

## License

MIT, see [LICENSE](LICENSE).
