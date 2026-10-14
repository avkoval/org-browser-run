;;; org-browser-run.el --- Run an org heading as a browser task via Claude + chrome-devtools-mcp -*- lexical-binding: t; -*-

;; Put point on a heading, M-x org-browser-run-stage (or -submit).  The
;; heading's subtree is sent to a headless `claude -p' whose only tools are
;; chrome-devtools-mcp attached to YOUR Chromium (CDP port 9222).  The agent
;; finds the matching open tab and performs the task there; progress streams
;; into *org-browser-run*, the outcome lands in the heading as
;; :BROWSER_STATUS: / :BROWSER_RUN: properties and a :BROWSER_LOG: drawer.
;;
;; Setup: see the "org-browser-run" section of ~/.emacs.d/README.org.
;;
;; In the org file:  #+PROPERTY: BROWSER_URL https://docs.google.com/document/d/<ID>/edit

(require 'org)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup org-browser-run nil
  "Run org headings as browser tasks through Claude."
  :group 'org)

(defcustom org-browser-run-claude-program "claude"
  "Claude Code CLI executable."
  :type 'string)

(defcustom org-browser-run-model "sonnet"
  "Model for the browser agent."
  :type 'string)

(defcustom org-browser-run-dir
  (file-name-directory (or load-file-name buffer-file-name "~/.emacs.d/org-browser-run/"))
  "Directory holding agent-prompt.md."
  :type 'directory)

(defcustom org-browser-run-allowed-states '("TODO")
  "TODO states that run without confirmation.  Other states ask first."
  :type '(repeat string))

(defcustom org-browser-run-context-ids '("howto")
  "CUSTOM_IDs of headings sent to the agent as general context."
  :type '(repeat string))

(defcustom org-browser-run-chrome-program "chromium"
  "Browser started by `org-browser-run-start-chrome'."
  :type 'string)

(defcustom org-browser-run-debug-port 9222
  "Remote debugging port of the controlled browser."
  :type 'integer)

(defcustom org-browser-run-profile-dir "~/.cache/org-browser-run/profile"
  "Dedicated browser profile.
Chrome 136+ refuses remote debugging on the default profile."
  :type 'directory)

(defcustom org-browser-run-comment-limit 2048
  "Google Docs comment/reply limit in UTF-8 bytes (about 1100 Cyrillic chars)."
  :type 'integer)

(defconst org-browser-run--log-buffer "*org-browser-run*")

(defvar org-browser-run--process nil)
(defvar org-browser-run--marker nil)
(defvar org-browser-run--mode nil)
(defvar org-browser-run--pending "")
(defvar org-browser-run--result nil)

;;; Browser

(defun org-browser-run--cdp-alive-p ()
  "Non-nil when the debugging endpoint answers."
  (condition-case nil
      (let ((buf (url-retrieve-synchronously
                  (format "http://127.0.0.1:%d/json/version" org-browser-run-debug-port) t t 2)))
        (when buf
          (prog1 (with-current-buffer buf
                   (and (eql (bound-and-true-p url-http-response-status) 200)
                        (save-excursion (goto-char (point-min)) (search-forward "\"Browser\"" nil t))
                        t))
            (kill-buffer buf))))
    (error nil)))

;;;###autoload
(defun org-browser-run-start-chrome (&optional url)
  "Start the controlled browser with remote debugging, optionally opening URL.
On first start log into Google in it once; the profile keeps the session."
  (interactive (list (and (derived-mode-p 'org-mode) (org-entry-get nil "BROWSER_URL" t))))
  (cond
   ((org-browser-run--cdp-alive-p)
    (message "Browser already listening on port %d" org-browser-run-debug-port))
   ((not (executable-find org-browser-run-chrome-program))
    (user-error "Browser program %s not found" org-browser-run-chrome-program))
   (t
    (let ((profile (expand-file-name org-browser-run-profile-dir))
          (buf (get-buffer-create " *org-browser-run-browser*")))
      (make-directory profile t)
      (with-current-buffer buf (erase-buffer))
      (apply #'start-process "org-browser-run-browser" buf org-browser-run-chrome-program
             (format "--remote-debugging-port=%d" org-browser-run-debug-port)
             (concat "--user-data-dir=" profile)
             (when url (list url)))
      (message "Starting %s…" org-browser-run-chrome-program)
      (let ((deadline (+ (float-time) 15)))
        (while (and (< (float-time) deadline) (not (org-browser-run--cdp-alive-p)))
          (sleep-for 0.5)))
      (if (org-browser-run--cdp-alive-p)
          (message "%s is up on port %d (profile %s)" org-browser-run-chrome-program
                   org-browser-run-debug-port profile)
        (display-buffer buf)
        (user-error "%s did not open port %d; see its output in the buffer above"
                    org-browser-run-chrome-program org-browser-run-debug-port))))))

;;; Collecting the task

(defun org-browser-run--entry-text (pos)
  "Text of the entry at POS up to its first child or next heading."
  (save-excursion
    (goto-char pos)
    (let ((beg (point)))
      (outline-next-heading)
      (buffer-substring-no-properties beg (point)))))

(defun org-browser-run--context ()
  "Plist describing the heading at point."
  (save-excursion
    (org-back-to-heading t)
    (let* ((beg (point))
           (end (save-excursion (org-end-of-subtree t t) (point)))
           (parent (save-excursion (when (org-up-heading-safe) (point))))
           (general (delq nil (mapcar (lambda (id)
                                        (let ((pos (org-find-property "CUSTOM_ID" id)))
                                          (when pos (org-browser-run--entry-text pos))))
                                      org-browser-run-context-ids))))
      (list :url (or (org-entry-get nil "BROWSER_URL" t) "")
            :outline (string-join (org-get-outline-path t t) " / ")
            :state (org-get-todo-state)
            :general (string-join general "\n")
            :section (if parent (org-browser-run--entry-text parent) "")
            :body (buffer-substring-no-properties beg end)))))

(defun org-browser-run--prompt (ctx mode)
  (format "MODE: %s\nTARGET_URL: %s\nOUTLINE: %s\nSTATE: %s\n
--- GENERAL CONTEXT ---\n%s\n--- SECTION CONTEXT ---\n%s\n--- TASK ---\n%s\n--- END ---\n
Do the TASK in the browser following your instructions and finish with the STATUS/TAB/DETAIL block."
          mode (plist-get ctx :url) (plist-get ctx :outline) (plist-get ctx :state)
          (plist-get ctx :general) (plist-get ctx :section) (plist-get ctx :body)))

(defun org-browser-run--mcp-config ()
  "Write the MCP config pointing chrome-devtools-mcp at the running browser."
  (let ((file (make-temp-file "org-browser-run-mcp-" nil ".json")))
    (with-temp-file file
      (insert (json-encode
               `((mcpServers
                  . ((live-chrome
                      . ((type . "stdio")
                         (command . "npx")
                         (args . ["-y" "chrome-devtools-mcp@latest"
                                  ,(format "--browserUrl=http://127.0.0.1:%d" org-browser-run-debug-port)
                                  "--no-usage-statistics" "--no-performance-crux"])))))))))
    file))

(defun org-browser-run--oversized (body)
  "UTF-8 byte sizes of example blocks in BODY over the comment limit."
  (let ((start 0) sizes)
    (while (string-match "^[ \t]*#\\+begin_example[^\n]*\n\\(\\(?:.\\|\n\\)*?\\)\n[ \t]*#\\+end_example"
                         body start)
      (let ((n (string-bytes (encode-coding-string (match-string 1 body) 'utf-8))))
        (when (> n org-browser-run-comment-limit) (push n sizes)))
      (setq start (match-end 0)))
    (nreverse sizes)))

;;; Running

(defun org-browser-run--log (fmt &rest args)
  (with-current-buffer (get-buffer-create org-browser-run--log-buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (apply #'format fmt args) "\n"))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (set-window-point w (point-max)))))

(defun org-browser-run--short (input)
  (let ((s (if input (json-encode input) "")))
    (if (> (length s) 160) (concat (substring s 0 160) "…") s)))

(defun org-browser-run--handle-event (ev)
  (pcase (alist-get 'type ev)
    ("assistant"
     (dolist (item (alist-get 'content (alist-get 'message ev)))
       (pcase (alist-get 'type item)
         ("text" (org-browser-run--log "%s" (alist-get 'text item)))
         ("tool_use" (org-browser-run--log "  → %s %s"
                                           (string-remove-prefix "mcp__live-chrome__" (alist-get 'name item))
                                           (org-browser-run--short (alist-get 'input item)))))))
    ("result"
     (setq org-browser-run--result (or (alist-get 'result ev) ""))
     (org-browser-run--log "── done: %s, %.1fs, $%.3f"
                           (alist-get 'subtype ev)
                           (/ (or (alist-get 'duration_ms ev) 0) 1000.0)
                           (or (alist-get 'total_cost_usd ev) 0)))))

(defun org-browser-run--filter (_proc chunk)
  (setq org-browser-run--pending (concat org-browser-run--pending chunk))
  (let ((lines (split-string org-browser-run--pending "\n")))
    (setq org-browser-run--pending (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (condition-case nil
            (org-browser-run--handle-event (json-parse-string line :object-type 'alist :array-type 'list))
          (error (org-browser-run--log "%s" line)))))))

(defun org-browser-run--field (name text)
  (when (string-match (format "^%s:[ \t]*\\(.*\\(?:\n[ \t]+.*\\)*\\)" name) text)
    (string-trim (match-string 1 text))))

(defun org-browser-run--record (status tab detail)
  "Write the outcome into the heading the run started from."
  (let ((m org-browser-run--marker))
    (when (and m (marker-buffer m))
      (with-current-buffer (marker-buffer m)
        (org-with-wide-buffer
         (goto-char m)
         (let ((ts (format-time-string (org-time-stamp-format t t))))
           (org-entry-put nil "BROWSER_STATUS" status)
           (org-entry-put nil "BROWSER_RUN" ts)
           (let* ((limit (save-excursion (outline-next-heading) (point)))
                  (line (format "- %s %s %s — %s%s\n" ts org-browser-run--mode status
                                (replace-regexp-in-string "\n[ \t]*" "\n  " (or detail ""))
                                (if (string-empty-p (or tab "")) "" (format "\n  Вкладка: %s" tab)))))
             (if (save-excursion (re-search-forward "^[ \t]*:BROWSER_LOG:[ \t]*$" limit t))
                 (progn (re-search-forward "^[ \t]*:BROWSER_LOG:[ \t]*$" limit t)
                        (re-search-forward "^[ \t]*:END:[ \t]*$" limit t)
                        (beginning-of-line)
                        (insert line))
               (org-end-of-meta-data)
               (insert ":BROWSER_LOG:\n" line ":END:\n")))))))))

(defun org-browser-run--sentinel (proc _event)
  (unless (process-live-p proc)
    (let* ((text (or org-browser-run--result ""))
           (status (or (org-browser-run--field "STATUS" text)
                       (if (zerop (process-exit-status proc)) "unknown" "error")))
           (status (car (split-string status "[ |]" t)))
           (detail (or (org-browser-run--field "DETAIL" text)
                       (if (string-empty-p text) (format "claude exited with %d" (process-exit-status proc))
                         (truncate-string-to-width text 300))))
           (tab (org-browser-run--field "TAB" text)))
      (org-browser-run--record status tab detail)
      (when-let* ((cfg (process-get proc 'mcp-config))) (ignore-errors (delete-file cfg)))
      (setq org-browser-run--process nil)
      (message "org-browser-run: %s — %s" status detail))))

(defun org-browser-run--start (mode)
  (unless (derived-mode-p 'org-mode) (user-error "Not in an org buffer"))
  (when (process-live-p org-browser-run--process)
    (user-error "A browser run is already in progress (M-x org-browser-run-kill to stop it)"))
  (when (org-before-first-heading-p)
    (user-error "Put point on the task heading you want to run"))
  (unless (org-browser-run--cdp-alive-p)
    (if (y-or-n-p (format "No browser on port %d. Start %s now? "
                          org-browser-run-debug-port org-browser-run-chrome-program))
        (progn (org-browser-run-start-chrome (org-entry-get nil "BROWSER_URL" t))
               (user-error "Browser started: open the document tab (log in once), then run again"))
      (user-error "Aborted")))
  (let* ((ctx (org-browser-run--context))
         (state (plist-get ctx :state)))
    (when (string-empty-p (plist-get ctx :url))
      (unless (y-or-n-p "No BROWSER_URL property (add #+PROPERTY: BROWSER_URL …); let the agent guess the tab? ")
        (user-error "Aborted")))
    (unless (or (equal mode "locate")
                (member state org-browser-run-allowed-states)
                (y-or-n-p (format "Heading is %s, run anyway? " (or state "without state"))))
      (user-error "Aborted"))
    (unless (equal mode "locate")
      (let ((over (org-browser-run--oversized (plist-get ctx :body))))
        (when (and over
                   (not (y-or-n-p
                         (format "Text block %s bytes > %d (Google Docs comment limit). Run anyway? "
                                 (mapconcat #'number-to-string over ", ")
                                 org-browser-run-comment-limit))))
          (user-error "Aborted: shorten the text first"))))
    (when (and (equal mode "submit")
               (not (yes-or-no-p (format "SUBMIT «%s» in the browser? " (plist-get ctx :outline)))))
      (user-error "Aborted"))
    (let* ((default-directory (file-name-as-directory org-browser-run-dir))
           (system (with-temp-buffer
                     (insert-file-contents (expand-file-name "agent-prompt.md" org-browser-run-dir))
                     (buffer-string)))
           (cfg (org-browser-run--mcp-config)))
      (setq org-browser-run--marker (save-excursion (org-back-to-heading t) (point-marker))
            org-browser-run--mode mode
            org-browser-run--pending ""
            org-browser-run--result nil)
      (with-current-buffer (get-buffer-create org-browser-run--log-buffer)
        (special-mode)
        (let ((inhibit-read-only t)) (erase-buffer)))
      (org-browser-run--log "── %s: %s" mode (plist-get ctx :outline))
      (display-buffer org-browser-run--log-buffer)
      (setq org-browser-run--process
            (make-process
             :name "org-browser-run"
             :command (list org-browser-run-claude-program
                            "-p" (org-browser-run--prompt ctx mode)
                            "--model" org-browser-run-model
                            "--append-system-prompt" system
                            "--mcp-config" cfg
                            "--strict-mcp-config"
                            "--allowedTools" "mcp__live-chrome"
                            "--disallowedTools" "Bash" "Edit" "Write" "NotebookEdit" "WebFetch" "WebSearch"
                            "--output-format" "stream-json" "--verbose")
             :connection-type 'pipe
             :noquery t
             :filter #'org-browser-run--filter
             :sentinel #'org-browser-run--sentinel))
      (process-send-eof org-browser-run--process)
      (process-put org-browser-run--process 'mcp-config cfg))))

;;;###autoload
(defun org-browser-run-locate ()
  "Only find the heading's place in the browser and leave it highlighted.
Opens the comment thread or highlights the text; types nothing."
  (interactive)
  (org-browser-run--start "locate"))

;;;###autoload
(defun org-browser-run-stage ()
  "Prepare the heading's action in the browser without sending or applying it."
  (interactive)
  (org-browser-run--start "stage"))

;;;###autoload
(defun org-browser-run-submit ()
  "Perform the heading's action in the browser, including the final click."
  (interactive)
  (org-browser-run--start "submit"))

;;;###autoload
(defun org-browser-run-kill ()
  "Stop the running browser agent."
  (interactive)
  (when (process-live-p org-browser-run--process)
    (kill-process org-browser-run--process)))

(provide 'org-browser-run)
;;; org-browser-run.el ends here
