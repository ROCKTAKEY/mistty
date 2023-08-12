;;; mistty.el --- One Terminal -*- lexical-binding: t -*-

;; Copyright (C) 2023 Stephane Zermatten

;; Author: Stephane Zermatten <szermatt@gmx.net>
;; Version: 0.1
;; Package-Requires: ((emacs "28.2"))
;; Keywords: convenience, unix
;; URL: http://github.com/szermatt/mixterm


;;; Commentary:
;; 

(require 'term)
(require 'seq)
(require 'subr-x)
(require 'text-property-search)
(require 'term/xterm)
(require 'url-util)

;;; Code:

(defvar mistty-osc-hook (list #'mistty-osc7)
  "Hook run when unknown OSC sequences have been received.

This hook is run on the term-mode buffer. It is passed the
content of OSC sequence - everything between OSC (ESC ]) and
ST (ESC \\ or \\a) and may chooose to handle or ignore them.

The current buffer is set to the term-mode buffer. The hook is
allowed to modify it, to add text properties, for example. In
such case, consider using `mistty-register-text-properties'.")

(defvar-local mistty-work-buffer nil
  "The main `mistty-mode' buffer.

This buffer keeps a modifiable history of all commands at the top
and a view of the terminal modified by the current command at the
bottom.

In normal mode, this is the buffer that's displayed to the user.
In fullscreen mode, this buffer is kept as historical scrollback
buffer that can be independently switched to with
`mistty-switch-to-scrollback-buffer'.

While there is normally a terminal buffer, available as
`mistty-term-buffer' as well as a process, available as
`mistty-term-proc' either or both of these might be nil, such as
after the process died.


This variable is available in both the work buffer and the term
buffer.")

(defvar-local mistty-term-buffer nil
  "Secondary `term-mode' buffer.

This buffer contains the current screen state, as drawn by the
different commands. In normal mode, changes made in this buffer
are normally copied to `mistty-work-buffer'. In fullscreen mode,
this is the buffer that's displayed to the user. In normal mode,
this buffer is hidden.

While there is normally a work buffer, available as
`mistty-work-buffer' as well as a process, available as
`mistty-term-proc` either or both of these might be nil in some
cases.

This variable is available in both the work buffer and the term
buffer.")

(defvar-local mistty-term-proc nil
  "The process that controls the terminal, usually a shell.

This process is associated to `mistty-term-buffer' and is set up
to output first to that buffer.

The process property `mistty-work-buffer' links the work buffer
and, for consistency, the process property `mistty-term-buffer'
links to the term buffer.

This variable is available in both the work buffer and the term
buffer.")

(defvar-local mistty-sync-marker nil
  "A marker that links `mistty-term-buffer' to `mistty-work-buffer'.

The region of the terminal that's copied to the work buffer
starts at `mistty-sync-marker' and ends at `(point-max)' on both
buffers. The two markers must always be kept in sync and updated
at the same time.

This variable is available in both the work buffer and the term
buffer.")

(defvar-local mistty-cmd-start-marker nil
  "Mark the end of the prompt; the beginning of the command line.

The region [`mistty-sync-marker', `mistty-cmd-start-marker']
marks the prompt of the command line, if one was detected. If no
prompt was detected, this marker points to the same position as
`mistty-sync-marker'.

This variable is available in the work buffer.")

(defvar-local mistty-sync-ov nil
  "An overlay that covers the region [`mistty-sync-marker', `(point-max)'].

This overlay covers the region of the work buffer that's
currently kept in sync with the terminal. MisTTY tries to send
any modifications made to this region to the terminal for
processing. Such modification might be rejected and eventually
undone, accepted or accepted with modifications.

The special keymap `mistty-prompt-map' is active when the pointer
is on this overlay.

This variable is available in the work buffer.")

(defvar-local mistty-bracketed-paste nil
  "Whether bracketed paste is enabled in the terminal.

This variable evaluates to true when bracketed paste is turned on
by the command that controls, to false otherwise.

This variable is available in the work buffer.")

(defvar-local mistty-fullscreen nil
  "Whether MisTTY is in full-screen mode.

When MisTTY is in full-screen mode, this variable evaluates to
true, the `term-mode' buffer is the buffer shown to the user,
while the `mistty-mode' buffer is kept aside, detached from the
process.

This variable is available in the work buffer.")

(defvar-local mistty--old-point nil
  "The position of the point captured in `pre-command-hook'.

It is used in the `post-command-hook'.

This variable is available in the work buffer.")

(defvar-local mistty--deleted-point-max nil
  "True if the end of work buffer was truncated.

This variable is available in the work buffer.")

(defvar-local mistty--point-follows-next-pmark nil
  "True if the point should be moved to the pmark.

This variable tells `mistty--term-to-work' that it should move
the point to the pmark next time it copies the state of the
terminal to the work buffer.

This variable is available in the work buffer.")

(defvar-local mistty--possible-prompt nil
  "Region of the work buffer identified as possible prompt.

This variable is either `nil' or a list that contains:
 - the start of the prompt, a position in the work buffer
 - the end of the prompt
 - the content of the prompt

While start and end points to positions in the work buffer, such
position might not contain any data yet - if they haven't been
copied from the terminal, or might contain data - if they have
since been modified.

This variable is available in the work buffer.")

(defvar-local mistty--pmark-after-last-term-to-work nil
  "The position of the pmark at the end of `mistty--term-to-work'.

This variable is meant for `mistty--term-to-work' to detect
whether the pmark has moved since its last call. It's not meant
to be modified or accessed by other functions.

This variable is available in the work buffer.")

(defvar-local mistty--inhibit-term-to-work nil
  "When true, prevent `mistty--term-to-work' from copying data.

When this variable is true, `mistty--term-to-work' does nothing
unless it is forced; it just sets
`mistty--inhibited-term-to-work'. This is useful to temporarily
prevent changes to the terminal to be reflected to the work
buffer and shown to the user.

This variable is available in the work buffer.")

(defvar-local mistty--inhibited-term-to-work nil
  "If true, the work buffer is known to be out-of-date.

This variable is set by `mistty--term-to-work' when copying data
from the terminal to the work buffer is disabled. It signals that
`mistty--term-to-work' should be called after setting
`mistty--term-to-work' to true again.

This variable is available in the work buffer.")

(defvar-local mistty--term-properties-to-add-alist nil
  "An alist of id to text properties to add to the term buffer.

This variable associates arbitrary symbols to property lists. It
is set by `mistty-register-text-properties' and read whenever
text is written to the terminal.

This variable is available in the work buffer.")

(defvar mistty--key-to-keyseq nil
  "A cache for a keymap from Emacs key to terminal sequences.

This is only meant to be accessed or set by `mistty-send-key'.

This variable is available in the work buffer.")

(defvar mistty--last-id 0
  "The last ID generated by `mistty--next-id'.

This variable is used to generate a new number every time
`mistty-next-id' is called. It is not meant to be accessed or
changed outside of this function.")

(eval-when-compile
  ;; defined in term.el
  (defvar term-home-marker))
 
(defconst mistty-left-str "\eOD"
  "Sequence to send to the process when the left arrow is pressed.")

(defconst mistty-right-str "\eOC"
  "Sequence to send to the process when the rightarrow is pressed.")

(defconst mistty-bracketed-paste-start-str "\e[200~"
  "Sequence sent to the terminal to enable bracketed paste.")

(defconst mistty-bracketed-paste-end-str "\e[201~"
  "Sequence sent to the terminal to disable bracketed paste.")

(defconst mistty--ws "[:blank:]\n\r"
  "A character class that matches spaces and newlines, for MisTTY.")

(defvar mistty-prompt-re "[#$%>.] *$"
  "Regexp used to identify prompts.

Strings that might be prompts are evaluated against this regexp,
without any command. This regexp should match something that
looks like a prompt.

When the user makes changes on or before such a line that looks
like a prompt, MisTTY attempts to send these changes to the
terminal, which might or might not work.")

(defvar mistty-positional-keys "\t\C-d\C-w\C-t\C-k\C-y"
  "Set of control characters that are defined as positional.

This is the set of control characters for which
`mistty-positional-p' returns true. See the documentation of that
function for the definition of a positional character.")

(defface mistty-fringe-face '((t (:background "purple" :foreground "purple")))
  "Color of the left fringe that indicates the synced region.

This is useful for debugging, when the display is a terminal."
  :group 'mistty)

(defface mistty-margin-face '((t (:foreground "purple")))
  "Color of the left margin that indicates the synced region.

This is useful for debugging, when the display is a window system."
  :group 'mistty)

(defvar mistty-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") 'mistty-next-prompt)
    (define-key map (kbd "C-c C-p") 'mistty-previous-prompt)
    (define-key map (kbd "C-c C-j") 'mistty-switch-to-fullscreen-buffer)
    (define-key map (kbd "C-e") 'mistty-end-of-line-or-goto-pmark)
    
    ;; mistty-send-last-key makes here some globally useful keys
    ;; available in mistty-mode buffers. More specific keys can be
    ;; input using C-q while mistty-prompt-map is active.
    (define-key map (kbd "C-c C-c") 'mistty-send-last-key)
    (define-key map (kbd "C-c C-z") 'mistty-send-last-key)
    (define-key map (kbd "C-c C-\\") 'mistty-send-last-key)
    (define-key map (kbd "C-c C-g") 'mistty-send-last-key)
    map)
  "Keymap of `mistty-mode'.

This map is active whenever the current buffer is in MisTTY mode.")

(defvar mistty-send-last-key-map '(keymap (t . mistty-send-last-key))
  "Keymap that sends everything to the terminal using `mistty-send-last-key'.

By default, it is bound to C-q in `mistty-prompt-map'.")

(defvar mistty-prompt-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'mistty-send-command)
    (define-key map (kbd "TAB") 'mistty-send-key)
    (define-key map (kbd "DEL") 'mistty-send-key)
    (define-key map (kbd "C-d") 'mistty-send-key)
    (define-key map (kbd "C-a") 'mistty-beginning-of-line)
    (define-key map (kbd "C-e") 'mistty-send-key)

    ;; While in a shell, when bracketed paste is on, this allows
    ;; sending a newline that won't submit the current command. This
    ;; is handy for editing multi-line commands in bash.
    (define-key map (kbd "S-<return>") 'newline)

    ;; While on the prompt, "quoted-char" turns into "send the next
    ;; key directly to the terminal".
    (define-key map (kbd "C-q") mistty-send-last-key-map)

    ;; Don't bother capturing single key-stroke modifications and
    ;; replaying them; just send them to the terminal. This works even
    ;; when the terminal doesn't accept editing.
    (define-key map [remap self-insert-command] 'mistty-send-key )
    map)
  "Keymap active on the part of `mistty-mode' synced with the terminal.

This map is active only on the portion of a MisTTY mode buffer
that is kept in sync with the terminal. Modifications made on
this portion of the buffer are copied to the terminal, when
possible.

It is used to send most key strokes and some keys directly to the
terminal.")

(defmacro mistty--with-live-buffer (buf &rest body)
  (declare (indent 1))
  (let ((tempvar (make-symbol "buf")))
    `(let ((,tempvar ,buf))
       (when (buffer-live-p ,tempvar)
         (with-current-buffer ,tempvar
           ,@body)))))

(define-derived-mode mistty-mode fundamental-mode "misTTY" "Line-based TTY."
  :interactive nil
  (setq buffer-read-only nil)
  (setq mistty-work-buffer (current-buffer))
  
  ;; scroll down only when needed. This typically keeps the point at
  ;; the end of the window. This seems to be more in-line with what
  ;; commands such as more expect than the default Emacs behavior.
  (setq-local scroll-conservatively 1024))
(put 'mistty-mode 'mode-class 'special)

(defun mistty--exec (program &rest args)
  (mistty-mode)
  (mistty--attach (mistty--create-term program args)))

(defun mistty--create-term (program args)
  (let ((term-buffer (generate-new-buffer (concat " mistty tty " (buffer-name)) 'inhibit-buffer-hooks)))
    (with-current-buffer term-buffer
      (term-mode)
      (setq-local term-char-mode-buffer-read-only t
                  term-char-mode-point-at-process-mark t
                  term-buffer-maximum-size 0
                  term-height (or (floor (window-screen-lines)) 24)
                  term-width (or (window-max-chars-per-line) 80))
      (term--reset-scroll-region)
      (term-exec term-buffer (buffer-name mistty-term-buffer) program nil args)
      (term-char-mode)
      (add-hook 'after-change-functions #'mistty--after-change-on-term nil t))
    term-buffer))

(defun mistty--after-change-on-term (beg end _old-length)
  (when (and mistty--term-properties-to-add-alist (> end beg))
    (when-let ((props (apply #'append
                       (mapcar #'cdr mistty--term-properties-to-add-alist))))
      (add-text-properties beg end props))))

(defun mistty-register-text-properties (id props)
  (mistty--with-live-buffer mistty-term-buffer
    (if-let ((cell (assq id mistty--term-properties-to-add-alist)))
        (setcdr cell props)
      (push (cons id props) mistty--term-properties-to-add-alist))))

(defun mistty-unregister-text-properties (id)
  (mistty--with-live-buffer mistty-term-buffer
    (when-let ((cell (assq id mistty--term-properties-to-add-alist)))
      (setq mistty--term-properties-to-add-alist 
          (delq cell
                mistty--term-properties-to-add-alist)))))

(defun mistty--next-id ()
  (setq mistty--last-id (1+ mistty--last-id)))

(defun mistty--attach (term-buffer)
  (let ((work-buffer (current-buffer))
        (proc (get-buffer-process term-buffer)))

    (when proc
      (process-put proc 'mistty-work-buffer work-buffer)
      (process-put proc 'mistty-term-buffer term-buffer))

    (setq mistty-term-proc proc)
    (setq mistty-term-buffer term-buffer)
    (setq mistty-sync-marker (mistty--create-or-reuse-marker mistty-sync-marker (point-max)))
    (setq mistty-cmd-start-marker (copy-marker mistty-sync-marker))
    (setq mistty-sync-ov (make-overlay mistty-sync-marker (point-max) nil nil 'rear-advance))

    (with-current-buffer term-buffer
      (setq mistty-term-proc proc)
      (setq mistty-work-buffer work-buffer)
      (setq mistty-term-buffer term-buffer)
      (setq mistty-sync-marker (mistty--create-or-reuse-marker mistty-sync-marker term-home-marker)))

    (overlay-put mistty-sync-ov 'keymap mistty-prompt-map)
    (overlay-put mistty-sync-ov 'modification-hooks (list #'mistty--modification-hook))
    (overlay-put mistty-sync-ov 'insert-behind-hooks (list #'mistty--modification-hook))

    ;; highlight the synced region in the fringe or margin
    (unless (window-system)
      (setq left-margin-width 1))
    (overlay-put
     mistty-sync-ov
     'line-prefix
     (propertize " " 'display
                 (if (window-system)
                     '(left-fringe vertical-bar mistty-fringe-face)
                   `((margin left-margin) ,(propertize "┃" 'face 'mistty-margin-face)))))

    (when proc
      (set-process-filter proc #'mistty-process-filter)
      (set-process-sentinel proc #'mistty-process-sentinel))

    (add-hook 'kill-buffer-hook #'mistty--kill-term-buffer nil t)
    (add-hook 'window-size-change-functions #'mistty--window-size-change nil t)
    (add-hook 'pre-command-hook #'mistty-pre-command nil t)
    (add-hook 'post-command-hook #'mistty-post-command nil t)
    
    (mistty--term-to-work)
    (when proc
      (mistty-goto-pmark))))

(defun mistty--create-or-reuse-marker (m initial-pos)
  (if (not (markerp m))
      (copy-marker initial-pos)
    (when (= 1 (marker-position m))
      (move-marker m initial-pos))
    m))

(defun mistty--detach (&optional keep-sync-markers)
  (remove-hook 'kill-buffer-hook #'mistty--kill-term-buffer t)
  (remove-hook 'window-size-change-functions #'mistty--window-size-change t)
  (remove-hook 'pre-command-hook #'mistty-pre-command t)
  (remove-hook 'post-command-hook #'mistty-post-command t)
  
  (when mistty-sync-ov
    (delete-overlay mistty-sync-ov)
    (setq mistty-sync-ov nil))
  (when mistty-term-proc
    (set-process-filter mistty-term-proc #'term-emulate-terminal)
    (set-process-sentinel mistty-term-proc #'term-sentinel)
    (setq mistty-term-proc nil))
  (when mistty-cmd-start-marker
    (move-marker mistty-cmd-start-marker nil)
    (setq mistty-cmd-start-marker nil))
  (unless keep-sync-markers
    (when mistty-sync-marker
      (move-marker mistty-sync-marker nil)
      (setq mistty-sync-marker nil))
    (mistty--with-live-buffer mistty-term-buffer
      (move-marker mistty-sync-marker nil)
      (setq mistty-sync-marker nil))))

(defun mistty--kill-term-buffer ()
  (let ((term-buffer mistty-term-buffer))
    (mistty--detach)
    (when (buffer-live-p term-buffer)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer term-buffer)))))
      
(defsubst mistty--buffer-p (buffer)
  "Return the BUFFER if the buffer is a live mistty buffer."
  (if (and buffer
           (bufferp buffer)
           (eq 'mistty-mode (buffer-local-value 'major-mode buffer))
           (buffer-live-p buffer)
           (buffer-local-value 'mistty-term-proc buffer)
           (process-live-p (buffer-local-value 'mistty-term-proc buffer)))
      buffer))

(defun mistty--buffers ()
  "List of live term buffers, sorted."
  (sort (delq nil (mapcar #'mistty--buffer-p (buffer-list)))
        (lambda (a b) (string< (buffer-name a) (buffer-name b)))))

(defun mistty ()
  (interactive)
  (let ((existing (mistty--buffers)))
    (if (or current-prefix-arg         ; command prefix was given
            (null existing)            ; there are no mistty buffers
            (and (null (cdr existing)) ; the current buffer is the only mistty buffer
                 (eq (current-buffer) (car existing))))
        ;; create a new one
        (mistty-create)
      (mistty--goto-next existing))))

(defun mistty--goto-next (existing)
  (let ((existing-tail (or (cdr (member (current-buffer) existing))
                           existing)))
    (if existing-tail
        (switch-to-buffer (car existing-tail))
      (error "no next mistty buffer"))))

(defun mistty-create ()
  (interactive)
  (with-current-buffer (generate-new-buffer "*mistty*")
    (mistty--exec (or explicit-shell-file-name shell-file-name (getenv "ESHELL")))
    (switch-to-buffer (current-buffer))
    ))

(defun mistty-process-sentinel (proc msg)
  (let ((work-buffer (process-get proc 'mistty-work-buffer))
        (term-buffer (process-buffer proc)))
    (if (buffer-live-p work-buffer)
        (when (memq (process-status proc) '(signal exit))
          (while (accept-process-output proc 0 0 t))
          (term-sentinel proc msg)
          (with-current-buffer work-buffer
            (save-restriction
              (widen)
              (mistty--term-to-work)
              (mistty--detach)))
          (kill-buffer term-buffer)))
    ;; detached term buffer
    (term-sentinel proc msg)))

(defun mistty--fs-process-sentinel (proc msg)
  (let ((process-dead (memq (process-status proc) '(signal exit)))
        (term-buffer (process-get proc 'mistty-term-buffer))
        (work-buffer (process-get proc 'mistty-work-buffer)))
    (cond
     ((and process-dead (buffer-live-p term-buffer) (buffer-live-p work-buffer))
      (mistty--leave-fullscreen proc "")
      (mistty-process-sentinel proc msg))
     ((and process-dead (not (buffer-live-p term-buffer)) (buffer-live-p work-buffer))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (process-get proc 'mistty-work-buffer)))
      (term-sentinel proc msg))
     (t (term-sentinel proc msg)))))

(defun mistty-process-filter (proc str)
  (let ((work-buffer (process-get proc 'mistty-work-buffer))
        (term-buffer (process-get proc 'mistty-term-buffer)))
    (cond
     ;; detached term buffer
     ((or (not (buffer-live-p work-buffer)) (not (buffer-live-p term-buffer)))
      (term-emulate-terminal proc str))
     
     ;; switch to fullscreen
     ((string-match "\e\\[\\(\\??47\\|\\?104[79]\\)h" str)
      (let ((smcup-pos (match-beginning 0)))
        (mistty-process-filter proc (substring str 0 smcup-pos))
        (with-current-buffer work-buffer
          (mistty--enter-fullscreen proc (substring str smcup-pos)))))
     
     ;; reset
     ((string-match "\ec" str)
      (let ((rs1-before-pos (match-beginning 0))
            (rs1-after-pos (match-end 0)))
        ;; The work buffer must be updated before sending the reset to
        ;; the terminal, or we'll lose data. This might interfere with
        ;; collecting and applying modifications, but then so would
        ;; reset.
        (let ((mistty--inhibited-term-to-work nil))
          (mistty-process-filter proc (substring str 0 rs1-before-pos)))
        (term-emulate-terminal proc (substring str rs1-before-pos rs1-after-pos))
        (with-current-buffer work-buffer
          (setq mistty-bracketed-paste nil)
          (mistty--reset-markers))
        (mistty-process-filter proc (substring str rs1-after-pos))))
     
     ;; normal processing
     (t (let ((inhibit-modification-hooks t)
              (inhibit-read-only t)
              (old-sync-position (mistty--with-live-buffer term-buffer (marker-position mistty-sync-marker)))
              (old-last-non-ws (mistty--with-live-buffer term-buffer (mistty--last-non-ws))))
          (mistty-emulate-terminal proc str)
          (mistty--with-live-buffer work-buffer
            (save-restriction
              (widen)
              (mistty--with-live-buffer term-buffer
                (goto-char (process-mark proc))
                (when (or (< mistty-sync-marker old-sync-position)
                          (< (point) mistty-sync-marker))
                  (mistty--reset-markers)
                  (setq mistty--point-follows-next-pmark t))
                (when (> (process-mark proc) old-last-non-ws) ;; on a new line
                  (mistty--detect-possible-prompt (process-mark proc))))
              (condition-case nil
                  (setq default-directory (buffer-local-value 'default-directory term-buffer))
                (error nil))
              (mistty--term-to-work))))))))

(defun mistty-goto-pmark ()
  (interactive)
  (let ((pmark (mistty--safe-pos (mistty-pmark))))
    (goto-char pmark)
    (dolist (win (get-buffer-window-list mistty-work-buffer nil t))
      (mistty--recenter win))))

(defun mistty--recenter (win)
  (with-current-buffer (window-buffer win)
    (when (and mistty-term-proc
               (or (eq (mistty-pmark) (window-point win))
                   (> (window-point win) (mistty--bol-pos-from (point-max) -3))))
        (with-selected-window win
          (recenter (- (1+ (count-lines
                            (window-point win) (point-max)))) t)))))

(defun mistty--detect-possible-prompt (pmark)
  (let* ((bol (mistty--bol-pos-from pmark)))
    (when (and (> pmark bol)
               (>= pmark (mistty--last-non-ws))
               (string-match
                mistty-prompt-re
                (mistty--safe-bufstring bol pmark)))
      (let ((end (+ bol (match-end 0)))
            (content (mistty--safe-bufstring bol (+ bol (match-end 0)))))
        (mistty--with-live-buffer mistty-work-buffer
          (setq mistty--possible-prompt
                (list (mistty--from-term-pos bol)
                      (mistty--from-work-pos end)
                      content)))))))
 
(defun mistty--reset-markers ()
  (mistty--with-live-buffer mistty-work-buffer
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (delete-region (mistty--last-non-ws) (point-max))
      (insert "\n"))
    (move-marker mistty-sync-marker (point-max))
    (move-marker mistty-cmd-start-marker (point-max)))
  (mistty--with-live-buffer mistty-term-buffer
    (save-excursion
      (goto-char term-home-marker)
      (skip-chars-forward mistty--ws)
      (move-marker mistty-sync-marker (point)))))

(defun mistty-emulate-terminal (proc str)
  "Handle special terminal codes, then call `term-emulate-terminal'.

This functions intercepts some extented sequences term.el. This
all should rightly be part of term.el."
  (cl-letf ((inhibit-modification-hooks nil)
            (start 0)
            ;; Using term-buffer-vertical-motion causes strange
            ;; issues; avoid it. Using mistty's window to compute
            ;; vertical motion is correct since the window dimension
            ;; are kept in sync with the terminal size. Falling back
            ;; to using the selected window, on the other hand, is
            ;; questionable.
            ((symbol-function 'term-buffer-vertical-motion)
             (lambda (count)
               (vertical-motion count (or (get-buffer-window mistty-work-buffer)
                                          (selected-window))))))
    (while (string-match "\e\\(\\[\\?\\(2004\\|25\\)[hl]\\|\\]\\(.*?\\)\\(\e\\\\\\|\a\\)\\)" str start)
      (let ((ext (match-string 1 str))
            (osc (match-string 3 str))
            (seq-start (match-beginning 0))
            (seq-end (match-end 0))
            (term-buffer (process-get proc 'mistty-term-buffer))
            (work-buffer (process-get proc 'mistty-work-buffer)))
        (cond
         ((equal ext "[?2004h") ; enable bracketed paste
          (term-emulate-terminal proc (substring str start seq-end))
          (mistty--with-live-buffer term-buffer
            (let ((props `(mistty-prompt-id ,(mistty--next-id))))
              ;; zsh enables bracketed paste only after having printed
              ;; the prompt.
              (unless (eq ?\n (char-before (point)))
                (add-text-properties (mistty--bol-pos-from (point)) (point) props))
              (mistty-register-text-properties 'mistty-bracketed-paste props)))
          (mistty--with-live-buffer work-buffer
            (setq mistty-bracketed-paste t)))
         ((equal ext "[?2004l") ; disable bracketed paste
          (term-emulate-terminal proc (substring str start seq-end))
          (mistty-unregister-text-properties 'mistty-bracketed-paste)
          (mistty--with-live-buffer work-buffer
            (setq mistty-bracketed-paste nil)))
         ((equal ext "[?25h") ; make cursor visible
          (term-emulate-terminal proc (substring str start seq-end))
          (mistty--with-live-buffer work-buffer
            (setq cursor-type t)))
         ((equal ext "[?25l") ; make cursor invisible
          (term-emulate-terminal proc (substring str start seq-end))
          (mistty--with-live-buffer work-buffer
            (setq cursor-type nil)))
         (osc
          (term-emulate-terminal proc (substring str start seq-start))
          (mistty--with-live-buffer term-buffer
            (let ((inhibit-read-only t))
              (run-hook-with-args 'mistty-osc-hook osc)))))
          (setq start seq-end)))
    (let ((final-str (substring str start)))
      (unless (zerop (length final-str))
        (term-emulate-terminal proc final-str)))))

(defun mistty--fs-process-filter (proc str)
  (let ((work-buffer (process-get proc 'mistty-work-buffer))
        (term-buffer (process-get proc 'mistty-term-buffer)))
    (if (and (string-match "\e\\[\\(\\??47\\|\\?104[79]\\)l\\(\e8\\|\e\\[\\?1048l\\)?" str)
             (buffer-live-p work-buffer)
             (buffer-live-p term-buffer))
        (let ((after-rmcup-pos (match-beginning 0)))
          (mistty-emulate-terminal proc (substring str 0 after-rmcup-pos))
          (with-current-buffer work-buffer
            (mistty--leave-fullscreen proc (substring str after-rmcup-pos))))
      ;; normal processing
      (mistty-emulate-terminal proc str))))

(defun mistty--maybe-bracketed-str (str)
  (let ((str (string-replace "\t" (make-string tab-width ? ) str)))
    (cond
     ((not mistty-bracketed-paste) str)
     ((not (string-match "[[:cntrl:]]" str)) str)
     (t (concat mistty-bracketed-paste-start-str
                str
                mistty-bracketed-paste-end-str
                mistty-left-str
                mistty-right-str)))))

(defun mistty-pmark ()
  (mistty--from-pos-of (process-mark mistty-term-proc) mistty-term-buffer))

(defun mistty--from-pos-of (pos buffer-of-pos)
  "Return the local equivalent to POS defined in BUFFER-OF-POS."
  (+ mistty-sync-marker (with-current-buffer buffer-of-pos
                         (- pos mistty-sync-marker))))

(defun mistty--from-term-pos (pos)
  (mistty--from-pos-of pos mistty-term-buffer))

(defun mistty--from-work-pos (pos)
  (mistty--from-pos-of pos mistty-work-buffer))

(defun mistty--disable-term-to-work ()
  (setq mistty--inhibit-term-to-work t))

(defun mistty--enable-term-to-work ()
  (setq mistty--inhibit-term-to-work nil)
  (when mistty--inhibited-term-to-work
    (mistty--term-to-work)))

(defun mistty--term-to-work (&optional forced)
  (if (and mistty--inhibit-term-to-work (not forced))
      (setq mistty--inhibited-term-to-work t)
    (let ((inhibit-modification-hooks t)
          (inhibit-read-only t)
          (old-point (point))
          properties)
      (setq mistty--inhibited-term-to-work nil)
      (with-current-buffer mistty-term-buffer
        (save-restriction
          (narrow-to-region mistty-sync-marker (point-max-marker))
          (setq properties (mistty--save-properties mistty-sync-marker))
          (with-current-buffer mistty-work-buffer
            (save-restriction
              (narrow-to-region mistty-sync-marker (point-max-marker))
              (replace-buffer-contents mistty-term-buffer)
              (mistty--restore-properties properties mistty-sync-marker)
              (when (> mistty-cmd-start-marker mistty-sync-marker)
                (mistty--set-prompt-properties
                 mistty-sync-marker mistty-cmd-start-marker))))))

      ;; detect prompt from bracketed-past region and use that to
      ;; restrict the sync region.
      (mistty--with-live-buffer mistty-work-buffer
        (when (process-live-p mistty-term-proc)
          (let ((prompt-beg
                 (let ((pos (mistty-pmark)))
                   (unless (and (> pos (point-min))
                                (get-text-property (1- pos) 'mistty-prompt-id))
                     (setq pos (previous-single-property-change
                                pos 'mistty-prompt-id nil mistty-sync-marker)))
                   (when (and (> pos (point-min))
                              (get-text-property (1- pos) 'mistty-prompt-id))
                     (setq pos (previous-single-property-change
                                pos 'mistty-prompt-id nil mistty-sync-marker)))
                   pos)))
            (when (and prompt-beg
                       (or (> prompt-beg mistty-sync-marker)
                           (and (= prompt-beg mistty-sync-marker)
                                (= mistty-sync-marker mistty-cmd-start-marker)))
                       (< prompt-beg (mistty-pmark)))
              (mistty--move-sync-mark prompt-beg
                                      (mistty-pmark))))))
      
      (mistty--with-live-buffer mistty-term-buffer
        ;; Next time, only sync the visible portion of the terminal.
        (when (< mistty-sync-marker term-home-marker)
          (mistty--move-sync-mark term-home-marker))
        
        ;; Truncate the term buffer, since scrolling back is available on
        ;; the work buffer anyways. This has to be done now, after syncing
        ;; the marker, and not in term-emulate-terminal, which is why
        ;; term-buffer-maximum-size is set to 0.
        (save-excursion
          (goto-char term-home-marker)
          (forward-line -5)
          (delete-region (point-min) (point))))

      ;; Move the point to the pmark, if necessary.
      (mistty--with-live-buffer mistty-work-buffer
        (when (process-live-p mistty-term-proc)
          (when (or mistty--point-follows-next-pmark
                    (null mistty--pmark-after-last-term-to-work)
                    (= old-point mistty--pmark-after-last-term-to-work))
              (mistty-goto-pmark))
          (setq mistty--point-follows-next-pmark nil)
          (setq mistty--pmark-after-last-term-to-work (mistty-pmark)))))))

(defun mistty--save-properties (start)
  (let ((pos start) intervals)
    (while (< pos (point-max))
      (let ((props (text-properties-at pos))
            (last-pos pos))
        (setq pos (next-property-change pos nil (point-max)))
        (push `(,(- last-pos start) ,(- pos start) ,props)
              intervals)))
    
    intervals))

(defun mistty--restore-properties (intervals start)
  (dolist (interval intervals)
    (pcase interval
      (`(,beg ,end ,props)
       (set-text-properties (+ beg start) (+ end start) props))
      (_ (error "invalid interval %s" interval)))))

(defun mistty--move-sync-mark (sync-pos &optional cmd-pos)
  (let ((chars-from-end (- (point-max) sync-pos))
        (prompt-length (if (and cmd-pos (> cmd-pos sync-pos))
                           (- cmd-pos sync-pos)
                         0)))
    (with-current-buffer mistty-term-buffer
      (move-marker mistty-sync-marker (- (point-max) chars-from-end)))
    (with-current-buffer mistty-work-buffer
      (let ((work-sync-pos (- (point-max) chars-from-end)))
        (mistty--set-prompt work-sync-pos (+ work-sync-pos prompt-length))))))

(defun mistty--move-sync-mark-with-shift (sync-pos cmd-start-pos shift)
  (let ((diff (- sync-pos mistty-sync-marker)))
    (with-current-buffer mistty-term-buffer
      (move-marker mistty-sync-marker (+ mistty-sync-marker diff shift))))
  (with-current-buffer mistty-work-buffer
    (mistty--set-prompt sync-pos cmd-start-pos)))

(defun mistty--set-prompt (sync-pos cmd-start-pos)
  (let ((cmd-start-pos (max sync-pos cmd-start-pos))
        (inhibit-read-only t)
        (inhibit-modification-hooks t))
    (when (> mistty-cmd-start-marker mistty-sync-marker)
      (remove-text-properties mistty-sync-marker mistty-cmd-start-marker '(read-only t)))
    (move-marker mistty-sync-marker sync-pos)
    (move-marker mistty-cmd-start-marker cmd-start-pos)
    (move-overlay mistty-sync-ov sync-pos (point-max))
    (when (> cmd-start-pos sync-pos)
      (mistty--set-prompt-properties sync-pos cmd-start-pos))))

(defun mistty--set-prompt-properties (start end)
  (add-text-properties
   start end
   (append
    '(mistty prompt
             field mistty-prompt
             read-only t
             rear-nonsticky t)
    (unless (get-text-property start 'mistty-prompt-id)
      `(mistty-prompt-id ,(mistty--next-id))))))

(defun mistty-send-raw-string (str)
  (when (and str (not (zerop (length str))))
    (with-current-buffer mistty-term-buffer
      (term-send-raw-string str))))

(defun mistty--at-prompt-1 (&optional inexact)
  (let ((pmark (mistty-pmark)))
    (if inexact
        (or (>= (point) pmark)
            (>= (mistty--bol-pos-from (point))
                (mistty--bol-pos-from pmark)))
        (= (point) pmark))))

(defun mistty--bol-pos-from (pos &optional n)
  (save-excursion
    (goto-char pos)
    (let ((inhibit-field-text-motion t))
      (line-beginning-position n))))

(defun mistty--eol-pos-from (pos)
  (save-excursion
    (goto-char pos)
    (let ((inhibit-field-text-motion t))
      (line-end-position))))

(defun mistty--last-non-ws ()
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward mistty--ws)
    (point)))

(defun mistty-send-command ()
  "Send the current command to the shell."
  (interactive)
  (mistty--maybe-realize-possible-prompt)
  (setq mistty--point-follows-next-pmark t)
  (mistty-send-raw-string "\C-m"))

(defun mistty-send-last-key (n)
  "Send the last key that was typed to the terminal.

This command extracts element of `this-command-key`, translates
it and sends it to the terminal.

This is a convenient variant to `mistty-send-key' which allows
burying key binding to send to the terminal inside of the C-c
keymap, leaving that key binding available to Emacs."
  (interactive "p")
  (mistty-send-key
   n (seq-subseq (this-command-keys-vector) -1)))

(defun mistty-positional-p (key)
  "Return true if KEY is a positional key.

A key is defined as positional if it traditionally have an effect
that modifies what is displayed on the terminal in a way that
depends on where the cursor is on the terminal. See also
`mistty-positional-keys' for the set of control keys that are
defined as positional.

MisTTY will attempt to move the terminal cursor to the current
point before sending such keys to the terminal.

Non-control characters are always positional, since they're
normally just inserted.

KEY must be a string or vector such as the ones returned by 'kbd'."
  (and (length= key 1)
       (characterp (aref key 0))
       (or 
        (seq-contains-p mistty-positional-keys (aref key 0))
        (not (string= "Cc"
                      (get-char-code-property (aref key 0)
                                              'general-category))))))
              
(defun mistty-send-key (&optional n key positional)
  "Send the current key sequence to the terminal.

This command sends N times the current key sequence, or KEY if it
is specified, directly to the terminal. If the key sequence is
positional or if POSITIONAL evaluates to true, MisTTY attempts to
move the terminal's cursor to the current point.

KEY must be a string or vector as would be returned by `kbd'."
  (interactive "p")
  (let ((n (or n 1))
        (key (or key (this-command-keys-vector))))
    (when (or positional (mistty-positional-p key))
      (when (get-pos-property (point) 'read-only)
        (signal 'text-read-only nil))
      (mistty-before-positional)
      (setq mistty--point-follows-next-pmark t))
    (if (and (length= key 1) (characterp (elt key 0)))
        (mistty-send-raw-string (make-string n (elt key 0)))
      (let ((keymap (or mistty--key-to-keyseq
                        (setq mistty--key-to-keyseq
                              (mistty-reverse-input-decode-map
                               xterm-function-map)))))
        (if-let ((translated-key (lookup-key keymap key)))
            (mistty-send-raw-string
             (mistty--repeat-string n (concat translated-key)))
          (error "unknown key %s" (key-description key)))))))

(defun mistty--reverse-input-decode-map-1 (event-type binding prefix dest-keymap)
  (let ((full-event (vconcat prefix (vector event-type))))
    (cond
     ((keymapp binding)
      (map-keymap
       (lambda (e b)
         (mistty--reverse-input-decode-map-1 e b full-event dest-keymap))
       binding))
     ((functionp binding))
     ((sequencep binding) ; a key seq
      (unless (lookup-key dest-keymap binding)
        (define-key dest-keymap binding full-event))))))

(defun mistty-reverse-input-decode-map (map)
  (let ((reverse-map (make-sparse-keymap)))
    (map-keymap
     (lambda (e b)
       (mistty--reverse-input-decode-map-1 e b [] reverse-map))
     map)
    
    reverse-map))

(defun mistty-beginning-of-line (&optional n)
  (interactive "p")
  (mistty--maybe-realize-possible-prompt)
  (beginning-of-line n))

(defun mistty-end-of-line-or-goto-pmark (&optional n)
  (interactive "p")
  (if (and (= 1 n) (eq last-command this-command) (/= (point) (mistty-pmark)))
      (mistty-goto-pmark)
    (end-of-line n)))

(defun mistty--modification-hook (_ov is-after orig-beg orig-end &optional old-length)
  (when (and is-after
             mistty-cmd-start-marker
             (>= orig-end mistty-cmd-start-marker))
    (let ((inhibit-read-only t)
          (beg (max orig-beg mistty-cmd-start-marker))
          (end (max orig-end mistty-cmd-start-marker))
          (old-end (max (+ orig-beg old-length) mistty-cmd-start-marker))
          shift pos)
      ;; Temporarily stop refreshing the work buffer while collecting modifications.
      (mistty--disable-term-to-work)
      
      ;; Mark the text that was inserted
      (put-text-property beg end 'mistty-change '(inserted))

      ;; Update the shift value of everything that comes after.
      (setq shift (- old-end end))
      (setq pos end)
      (while (< pos (point-max))
        (let ((next-pos (next-single-property-change pos 'mistty-change (current-buffer) (point-max))))
          (pcase (get-text-property pos 'mistty-change)
            (`(shift ,old-shift)
             (put-text-property pos next-pos 'mistty-change `(shift ,(+ old-shift shift))))
            ('() (put-text-property pos next-pos 'mistty-change `(shift ,shift))))
          (setq pos next-pos)))
      (when (and (> old-length 0) (= end (point-max)))
        (setq mistty--deleted-point-max t)))))

(defun mistty--collect-modifications (intervals)
  (let ((changes nil)
        (last-shift 0))
    (while intervals
      (pcase intervals
        ;; insert in the middle, possibly replacing a section of text
        (`((,start inserted) (,end shift ,end-shift) . ,_)
         (push (list (+ start last-shift)
                     (mistty--safe-bufstring start end)
                     (- (+ end end-shift) (+ start last-shift)))
               changes)
         ;; processed 2 entries this loop, instead of just 1
         (setq intervals (cdr intervals)))

        ;; insert at end, delete everything after
        (`((,start inserted) (,end deleted-to-end))
         (push (list (+ start last-shift)
                     (mistty--safe-bufstring start end)
                     -1)
               changes)
         ;; processed 2 entries this loop, instead of just 1
         (setq intervals (cdr intervals)))

        ;; insert at end
        (`((,start inserted))
         (push (list (+ start last-shift)
                     (mistty--safe-bufstring start (point-max))
                     0)
               changes))

        ;; delete a section of original text
        ((and `((,pos shift ,shift) . ,_)
              (guard (> shift last-shift)))
         (push (list (+ pos last-shift)
                     ""
                     (- shift last-shift))
               changes))

        ;; delete to the end of the original text
        (`((,pos deleted-to-end))
         (push (list (+ pos last-shift) "" -1)
               changes)))
      
      ;; prepare for next loop
      (pcase (car intervals)
        (`(,_ shift ,shift) (setq last-shift shift)))
      (setq intervals (cdr intervals)))
    changes))

(defun mistty--collect-modification-intervals ()
  (save-excursion
    (save-restriction
      (narrow-to-region mistty-cmd-start-marker (point-max))
      (let ((last-point (point-min))
            intervals last-at-point )
        (goto-char last-point)
        (while (let ((at-point (get-text-property (point) 'mistty-change)))
                 (when last-at-point
                   (push `(,last-point . ,last-at-point) intervals))
                 (setq last-at-point at-point)
                 (setq last-point (point))
                 (goto-char (next-single-property-change (point) 'mistty-change (current-buffer) (point-max)))
                 (< (point) (point-max))))
        (when last-at-point
          (push `(,last-point . ,last-at-point) intervals))
        (when mistty--deleted-point-max
          (push `(,(point-max) deleted-to-end) intervals))
        (setq mistty--deleted-point-max nil)
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t))
          (remove-text-properties (point-min) (point-max) '(mistty-change t)))
        
        (nreverse intervals)))))

(defun mistty--restrict-modification-intervals (intervals min-pos)
    (if (and (caar intervals) (>= (caar intervals) min-pos))
        (cons 0 intervals)
      
      ;; apply restrictions
      (while (pcase intervals
               ((and `((,_ . ,_ ) (,pos2 . ,_) . ,_) (guard (<= pos2 min-pos)))
                (setq intervals (cdr intervals))
                t)))
      
      ;; intervals now points to the first relevant section, which likely
      ;; starts before min-pos. 
      (let ((base-shift
             (pcase intervals
               (`((,_ shift ,shift) . ,_) shift)
               (`((,_ inserted) (,pos2 shift ,shift) . ,_)
                (+ shift (- pos2 min-pos)))
               (_ ;; other interval restrictions aren't supported
                nil))))
        (when (and base-shift intervals)
          (setcar (car intervals) min-pos)
          
          ;; shifts must be relative to base-shift
          (setq intervals
                (mapcar
                 (lambda (cur)
                   (pcase cur
                     (`(,pos shift ,shift) `(,pos shift ,(- shift base-shift)))
                     (_ cur)))
                 intervals))
          (cons base-shift intervals)))))

(defun mistty--modification-intervals-start (intervals)
  (caar intervals))

(defun mistty--modification-intervals-end (intervals)
  (pcase (car (last intervals))
    (`(,pos shift ,_) pos)
    (_ (point-max))))

(defun mistty--replay-modifications (intervals)
  (let ((initial-point (point))
        (intervals-start (mistty--modification-intervals-start intervals))
        (intervals-end (mistty--modification-intervals-end intervals))
        (modifications (mistty--collect-modifications intervals))
        first lower-limit upper-limit)
    (setq first (car modifications))
    (while modifications
      (let* ((m (car modifications))
             (orig-beg (nth 0 m))
             (content (nth 1 m))
             (old-length (nth 2 m))
             (pmark (mistty-pmark))
             (beg orig-beg)
             (end (+ orig-beg (length content)))
             (old-end (if (> old-length 0)
                          (+ orig-beg old-length)
                        (mistty--from-pos-of (with-current-buffer mistty-term-buffer (point-max))
                                             mistty-term-buffer)))
             (replay-seqs nil))
        (setq modifications (cdr modifications))

        (when lower-limit
          (setq beg (max lower-limit beg)))
        (when upper-limit
          (setq end (min upper-limit end)
                old-end (min upper-limit old-end)))

        (when (> end beg)
          (mistty--send-and-wait (mistty--move-str pmark beg 'will-wait))
          (setq pmark (mistty-pmark))
          ;; pmark is as close to beg as we can make it

          ;; We couldn't move pmark as far back as beg. Presumably, the
          ;; process mark points to the leftmost modifiable position of
          ;; the command line. Update the sync marker to start sync there
          ;; from now on and avoid getting this hook called unnecessarily.
          (when (and (> pmark beg)
                     (> (mistty--distance-on-term beg pmark) 0))
            (setq lower-limit pmark)
            (mistty--move-sync-mark (mistty--bol-pos-from pmark) pmark))
          
          (setq beg (max beg pmark)))

        (when (> old-end beg)
          (if (eq m first)
              (progn
                (mistty--send-and-wait
                 (mistty--move-str pmark old-end 'will-wait))
                (setq pmark (mistty-pmark))
                (when (and (> beg pmark)
                           (> (mistty--distance-on-term beg pmark) 0))
                  ;; If we couldn't even get to beg we'll have trouble with
                  ;; the next modifications, too, as they start left of this
                  ;; one. Remember that.
                  (setq upper-limit pmark))
                (setq old-end (max beg (min old-end pmark))))
            
            ;; after the first modification, just optimistically go to
            ;; old-end if upper-limit allows it.
            (push (mistty--move-str pmark old-end) replay-seqs)))

        ;; delete
        (when (> old-end beg)
          (push (mistty--repeat-string
                 (mistty--distance-on-term beg old-end) "\b")
                replay-seqs))
        
        ;; insert
        (when (> end beg)
          (push (mistty--maybe-bracketed-str
                 (substring content
                            (max 0 (- beg orig-beg))
                            (min (length content) (max 0 (- end orig-beg)))))
                replay-seqs))
        
        ;; for the last modification, move pmark back to point
        (when (and (null modifications)
                   (>= initial-point intervals-start)
                   (<= initial-point intervals-end))
          (setq mistty--point-follows-next-pmark t)
          (push (mistty--move-str
                 end
                 (if lower-limit (max lower-limit initial-point)
                     initial-point))
                replay-seqs))

        ;; send the content of replay-seqs
        (let ((replay-str (mapconcat #'identity (nreverse replay-seqs) "")))
          (if (null modifications)
              (progn
                ;; Wait for a response from replay-string before
                ;; refreshing the display. This way, we won't see any
                ;; intermediate results with the modifications
                ;; temporarily turned off.
                ;;
                ;; TODO: what if there's no response from replay-str?
                ;; Add a timeout to call term-to-work after some delay
                ;; if no answer has come.
                (setq mistty--inhibit-term-to-work nil
                      mistty--inhibited-term-to-work nil)
                (mistty-send-raw-string replay-str))
            (mistty--send-and-wait replay-str)
            ))))))

(defun mistty--send-and-wait (str)
  (when (and str (not (zerop (length str))))
    (mistty-send-raw-string str)
    (when (accept-process-output mistty-term-proc 0 500 t) ;; TODO: tune the timeout
      (while (accept-process-output mistty-term-proc 0 nil t)))))

(defun mistty--move-str (from to &optional will-wait)
  (let ((diff (mistty--distance-on-term from to)))
    (if (zerop diff)
        nil
      (let ((distance (abs diff))
            (direction
             (if (< diff 0) mistty-left-str mistty-right-str))
            (reverse-direction
             (if (< diff 0) mistty-right-str mistty-left-str)))
      (concat
       (mistty--repeat-string distance direction)
       (if will-wait
           ;; Send a no-op right/left pair so that if, for example, it's
           ;; just not possible to go left anymore, the connected process
           ;; might still send *something* back and mistty--send-and-wait
           ;; won't have to time out.
           (concat reverse-direction direction)
         ""))))))

(defun mistty--safe-pos (pos)
  (min (point-max) (max (point-min) pos)))

(defun mistty--distance-on-term (beg end)
  "Compute the number of cursor moves necessary to get from BEG to END.

This function skips over the `term-line-wrap' newlines introduced
by term as if they were not here.

While it takes BEG and END as work buffer positions, it looks in
the term buffer to figure out, so it's important for the BEG and
END section to be valid in the term buffer."
  (with-current-buffer mistty-term-buffer
    (let ((beg (mistty--safe-pos (mistty--from-pos-of (min beg end) mistty-work-buffer)))
          (end (mistty--safe-pos (mistty--from-pos-of (max beg end) mistty-work-buffer)))
          (sign (if (< end beg) -1 1)))
      (let ((pos beg) (nlcount 0))
        (while (and (< pos end) (setq pos (text-property-any pos end 'term-line-wrap t)))
          (setq pos (1+ pos))
          (setq nlcount (1+ nlcount)))
        (* sign (- (- end beg) nlcount))))))

(defun mistty--repeat-string (count elt)
  (let ((elt-len (length elt)))
    (if (= 1 elt-len)
        (make-string count (aref elt 0))
      (let ((str (make-string (* count elt-len) ?\ )))
        (dotimes (i count)
          (dotimes (j elt-len)
            (aset str (+ (* i elt-len) j) (aref elt j))))
        str))))

(defun mistty-next-prompt (n)
  (interactive "p")
  (let ((pos (point))
        found)
    ;; skip current prompt
    (when (and (eq 'prompt (get-text-property pos 'mistty))
               (not (get-text-property pos 'field)))
      (setq pos (next-single-property-change pos 'mistty-prompt-id nil (point-max))))
    ;; go to next prompt(s)
    (dotimes (_ n)
      (if (and (setq found (text-property-any pos (point-max) 'mistty 'prompt))
               (setq pos (next-single-property-change found 'mistty-prompt-id nil (point-max))))
          (if (get-text-property found 'field)
              (goto-char (next-single-property-change found 'field nil pos))
            (goto-char found))
        
        (error "No next prompt")))))

(defun mistty-previous-prompt (n)
  (interactive "p")
  (let ((not-current nil))
    (when (eq 'mistty-prompt
              (or (get-text-property (point) 'field)
                  (get-text-property (1- (point)) 'field)))
      (setq not-current t)
      (goto-char (1- (point))))
    (dotimes (_ n)
      (let ((match (text-property-search-backward 'mistty-prompt-id nil nil not-current)))
        (unless match
          (error "No previous prompt"))
        (goto-char (prop-match-beginning match)))
      (when (get-text-property (point) 'field)
        (goto-char (next-single-property-change (point) 'field)))
      (setq not-current t))))

(defun mistty-pre-command ()
  (setq mistty--old-point (point)))

(defun mistty-post-command ()
  ;; Show cursor again if the command moved the point.
  (when (and mistty--old-point (/= (point) mistty--old-point))
    (setq cursor-type t))
  
  (run-at-time 0 nil #'mistty-post-command-1 mistty-work-buffer))

(defun mistty-post-command-1 (buf)
  (mistty--with-live-buffer buf
    (save-restriction
      (widen)
    (when (and (process-live-p mistty-term-proc)
               (buffer-live-p mistty-term-buffer))
      (let* ((intervals (mistty--collect-modification-intervals))
             (intervals-end (mistty--modification-intervals-end intervals))
             (modifiable-limit (mistty--bol-pos-from (point-max) -5))
             restricted)
        (cond
         ;; nothing to do
         ((null intervals)
          (mistty--maybe-pmark-to-point))

         ;; modifications are part of the current prompt; replay them
         ((mistty-on-prompt-p (mistty-pmark))
          (mistty--replay-modifications intervals))

         ;; modifications are part of a possible prompt; realize it, keep the modifications before the
         ;; new prompt and replay the modifications after the new prompt.
         ((and (mistty--possible-prompt-p)
               (setq restricted (mistty--restrict-modification-intervals intervals (nth 0 mistty--possible-prompt))))
          (mistty--realize-possible-prompt (car restricted))
          (mistty--replay-modifications (cdr restricted)))

         ;; leave all modifications if there's enough of an unmodified section at the end
         ((and intervals-end (< intervals-end modifiable-limit))
          (mistty--move-sync-mark (mistty--bol-pos-from intervals-end 2)))

         ;; revert modifications
         (t
          (mistty--term-to-work 'forced)
          (mistty--maybe-pmark-to-point)))
        
        ;; re-enable term-to-work in all cases.
        (mistty--enable-term-to-work))))))

(defun mistty--maybe-pmark-to-point ()
  (when (and mistty--old-point
             (/= (point) mistty--old-point)
             (markerp mistty-sync-marker)
             (>= (point) mistty-sync-marker)
             (process-live-p mistty-term-proc)
             (buffer-live-p mistty-term-buffer)
             (mistty-on-prompt-p (point)))
    (mistty-send-raw-string (mistty--move-str (mistty-pmark) (point)))))

(defun mistty--window-size-change (_win)
  (when (process-live-p mistty-term-proc)
    (let* ((adjust-func (or (process-get mistty-term-proc 'adjust-window-size-function)
                            window-adjust-process-window-size-function))
           (size (funcall adjust-func mistty-term-proc
                          (get-buffer-window-list mistty-work-buffer nil t))))
      (when size
        (mistty--set-process-window-size (car size) (cdr size)))))
  (dolist (win (get-buffer-window-list mistty-work-buffer nil t))
    (mistty--recenter win)))

(defun mistty--set-process-window-size (width height)
  (mistty--with-live-buffer mistty-term-buffer
    (set-process-window-size mistty-term-proc height width)
    (term-reset-size height width)))

(defun mistty--enter-fullscreen (proc terminal-sequence)
  (mistty--with-live-buffer (process-get proc 'mistty-work-buffer)
    (mistty--detach 'keep-sync-markers)
    (setq mistty-fullscreen t)

    (let ((msg
           "Fullscreen mode ON. C-c C-j switches between the tty and scrollback buffer."))
      (save-excursion
        (goto-char (point-max))
        (insert msg)
      (message msg)))
      
    (let ((bufname (buffer-name)))
      (rename-buffer (generate-new-buffer-name (concat bufname " scrollback")))
      (with-current-buffer mistty-term-buffer
        (local-set-key [remap term-line-mode] #'mistty-switch-to-scrollback-buffer)
        (rename-buffer bufname)
        (turn-on-font-lock)))
    (mistty--replace-buffer-everywhere mistty-work-buffer mistty-term-buffer)


    (set-process-filter proc #'mistty--fs-process-filter)
    (set-process-sentinel proc #'mistty--fs-process-sentinel)
    
    (when (length> terminal-sequence 0)
      (funcall (process-filter proc) proc terminal-sequence))))

(defun mistty--leave-fullscreen (proc terminal-sequence)
  (mistty--with-live-buffer (process-get proc 'mistty-work-buffer)
    (save-restriction
      (widen)
    (setq mistty-fullscreen nil)

    (mistty--attach (process-buffer proc))
    
    (let ((bufname (buffer-name mistty-term-buffer)))
      (with-current-buffer mistty-term-buffer
        (rename-buffer (generate-new-buffer-name (concat " mistty tty " bufname))))
      (rename-buffer bufname))

    (mistty--replace-buffer-everywhere mistty-term-buffer mistty-work-buffer)
    (with-current-buffer mistty-term-buffer
      (font-lock-mode -1))

    (when (length> terminal-sequence 0)
      (funcall (process-filter proc) proc terminal-sequence)))))

(defun mistty--replace-buffer-everywhere (oldbuf newbuf)
  (walk-windows
   (lambda (win)
     (let ((prev-buffers (window-prev-buffers win))
           (modified nil))
       (when (eq (window-buffer win) oldbuf)
         (set-window-buffer win newbuf)
         (setq modified t))
       (dolist (entry prev-buffers)
         (when (eq (car entry) oldbuf)
           (setcar entry newbuf)
           (setq modified t)))
       (when modified
         (set-window-prev-buffers win prev-buffers))))))

(defun mistty-switch-to-fullscreen-buffer ()
  (interactive)
  (if (and mistty-fullscreen (buffer-live-p mistty-term-buffer))
      (switch-to-buffer mistty-term-buffer)
    (error "No fullscreen buffer available.")))

(defun mistty-switch-to-scrollback-buffer ()
  (interactive)
  (if (and (buffer-live-p mistty-work-buffer)
           (buffer-local-value 'mistty-fullscreen mistty-work-buffer))
      (switch-to-buffer mistty-work-buffer)
    (error "No scrollback buffer available.")))

(defun mistty-on-prompt-p (pos)
  (and (>= pos mistty-cmd-start-marker)
       (or mistty-bracketed-paste
           (and 
            (> mistty-cmd-start-marker mistty-sync-marker)
            (>= pos mistty-cmd-start-marker)
            (<= pos (mistty--eol-pos-from mistty-cmd-start-marker))))))

(defun mistty-before-positional ()
  (let ((pmark (mistty-pmark)))
    (when (and (not (= pmark (point)))
               (mistty--maybe-realize-possible-prompt))
      (mistty-send-raw-string (mistty--move-str pmark (point))))))

(defun mistty--maybe-realize-possible-prompt ()
  (when (and (not (mistty-on-prompt-p (point)))
             (mistty--possible-prompt-p)
             (mistty--possible-prompt-contains (point)))
    (mistty--realize-possible-prompt)
    t))

(defun mistty--realize-possible-prompt (&optional shift)
  (pcase mistty--possible-prompt
    (`(,start ,end ,_ )
     (if shift
         (mistty--move-sync-mark-with-shift start end shift)
       (mistty--move-sync-mark start end)))
    (_ (error "no possible prompt"))))

(defun mistty--possible-prompt-p ()
  (pcase mistty--possible-prompt
    (`(,start ,end ,content)
     (let ((pmark (mistty-pmark)))
       (and (>= end mistty-cmd-start-marker)
            (>= pmark end)
            (or (> pmark (point-max))
                    (<= pmark (mistty--bol-pos-from start 2)))
            (string= content (mistty--safe-bufstring start end)))))))

(defun mistty--possible-prompt-contains (pos)
  (pcase mistty--possible-prompt
    (`(,start ,line-start ,_)
     (and (>= pos line-start) (<= pos (mistty--eol-pos-from start))))))

(defun mistty-osc7 (osc-seq)
  (when (string-match "7;file://\\([^/]*\\)\\(/.*\\)" osc-seq)
    (let ((hostname (url-unhex-string (match-string 1 osc-seq)))
          (path (url-unhex-string (match-string 2 osc-seq))))
      (when (and (string= hostname (system-name))
                 (file-directory-p path))
        (cd path)))))

(defun mistty--safe-bufstring (start end)
  (let ((start (max (point-min) (min (point-max) start)))
        (end (max (point-min) (min (point-max) end))))
    (if (> end start)
        (buffer-substring-no-properties start end)
      "")))

(provide 'mistty)

;;; mistty.el ends here
