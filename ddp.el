;;; ddp.el --- Dynamic Data Processor with cmd tools -*- lexical-binding: t -*-

;; Copyright (C) 2025 Eki Zhang

;; Author: Eki Zhang <liuyinz@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools
;; Homepage: https://github.com/eki3z/ddp.el

;; This file is not a part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is not a part of GNU Emacs.

;;; Commentary:

;; This package provides a framework to create interactive commands for filtering
;; content using command-line tools (e.g., yq, jq) asynchronously. It supports
;; buffers, regions, or files, with debounced updates, font-locked output, and
;; a customizable minibuffer interface with history and key bindings.

;;; Code:

(require 'subr-x)
(require 'pcase)
(require 'seq)
(require 'ansi-color)

(eval-when-compile
  (require 'cl-lib))

(declare-function display-line-numbers-mode "display-line-numbers")
(declare-function posframe-workable-p "posframe")
(declare-function posframe--find-existing-posframe "posframe")
(declare-function posframe-poshandler-frame-center "posframe")
(declare-function posframe-delete-frame "posframe")
(declare-function posframe-show "posframe")
(declare-function posframe-hide "posframe")

(defvar display-line-numbers-mode)

(defgroup ddp nil
  "Dynamic Data Processor for Emacs."
  :group 'tools)

(defcustom ddp-debounce-delay 0.5
  "Default delay in seconds before updating output after typing stops."
  :type 'float
  :group 'ddp)

(defcustom ddp-display-method 'window
  "How to display ddp output.
Value is one of:
  - `window' : Display output in window.
  - `posframe' : Display output in posframe."
  :type '(choice (const :tag "Window" window)
                 (const :tag "Posframe" posframe))
  :group 'ddp)

(defcustom ddp-display-style 'grow
  "Default display style for the ddp output display.
Value is one of:
  - `fixed' : Use a fixed height (MIN),
  - `fit'   : Adjust height to fit content, between MIN and MAX.
  - `grow'  : Start at MIN, only increase (up to MAX) as content grows."
  :type '(choice (const :tag "Fixed height" fixed)
                 (const :tag "Fit to content" fit)
                 (const :tag "Grow only" grow))
  :group 'ddp)

(defcustom ddp-height-range '(10 . 25)
  "Default height range for the ddp output display.
The value is a cons cell (MIN . MAX), where:
- MIN is the minimum height in lines.
- MAX is the maximum height in lines."
  :type '(cons (integer :tag "Minimum height")
               (integer :tag "Maximum height"))
  :group 'ddp)

(defvar ddp-plist nil
  "Plist for the current running ddp command.")

(defface ddp-waiting-status
  '((t :inherit (shadow bold)))
  "Face used to highlight ddp waiting status."
  :group 'ddp)

(defface ddp-running-status
  '((t :inherit (warning bold)))
  "Face used to highlight ddp running status."
  :group 'ddp)

(defface ddp-succeed-status
  '((t :inherit (success bold)))
  "Face used to highlight ddp succeed status."
  :group 'ddp)

(defface ddp-null-status
  '((t :inherit (font-lock-escape-face bold)))
  "Face used to highlight ddp null status."
  :group 'ddp)

(defface ddp-error-status
  '((t :inherit (error bold)))
  "Face used to highlight ddp error status."
  :group 'ddp)

(defvar-keymap ddp-local-map
  :doc "Default keymap for ddp minibuffer commands."
  :parent minibuffer-local-map
  "C-c c" #'ddp-copy-output
  "C-c s" #'ddp-save-output
  "C-c k" #'ddp-clear-query
  "C-c m" #'ddp-modify-cmd
  "C-c w" #'ddp-cycle-output-format
  "C-c y" #'ddp-copy-as-shell-command
  "C-c t" #'ddp-toggle-display-method)


;;; Macros

;;;###autoload
(defmacro ddp-bind (props &rest body)
  "Bind properties from `ddp-plist' and execute BODY.

This macro uses `cl-destructuring-bind' to extract specified properties
from `ddp-plist', a property list storing ddp command state, and makes
them available as variables within BODY. The properties in PROPS are treated
as keywords (e.g.,:exec, :cmd), and unrecognized keys in `ddp-plist' are
 ignored.

Parameters:
- PROPS: A list of symbols representing keys to bind from `ddp-plist' (e.g.,
  (:exec :cmd :output)).
- BODY: The forms to execute with the bound variables."
  (declare (indent defun) (doc-string 2))
  `(cl-destructuring-bind (&key ,@props &allow-other-keys)
       ddp-plist
     ,@body))

;;;###autoload
(defmacro ddp-define-command (name docstring &rest props)
  "Define an interactive command NAME for a command-line tool.

DOCSTRING is the documentation string for the command, describing its purpose.

PROPS is a property list with the following keys:
  :url       - A string providing the source or homepage of the executable
               used in error messages if :exec is not found.
  :exec      - The executable name (required, e.g., \"yq\").
               This is the command-line tool to invoke.
  :cmd       - A string (required) with placeholders:
               %e (replaced by :exec), %q (replaced by :query),
               %f (replaced by :file or :temp if set).
               Example: \"%e -C %q %f\"
  :delay     - Debounce delay in seconds before updating output
               (default: `ddp-debounce-delay', typically 0.6).
  :ansi      - Specifies whether to fontify output buffer with ANSI color.
               (default: nil)
  :mode      - Major mode for output buffer if needed.
               (default: `fundamental-mode')
  :method    - Specifies to display output in posframe or window.
               - `window' : Display output in window.
               - `posframe' : Display output in posframe.
  :style     - Specifies how window height update.
               - `fixed' : Use a fixed height (MIN),
               - `fit'   : Adjust height to fit content, between MIN and MAX.
               - `grow'  : Start at MIN, increase (up to MAX) as content grows.
  :support   - A list of support formats
               Example: (\"yaml\" \"toml\" ...)
  :pred      - An alist for customizing functions for behaviors
               Example: ((mode . XX-mode-pred)
                         (read . XX-read-format-pred)
                         (write . XX-write-format-pred))
               Using these predicate functions to setup properties dynamically,
               get necessary information from `ddp-plist' variable.
  :bind      - An alist for minibuffer local keybindings for command,
               Example: ((KEY . COMMAND))

The macro defines a command ddp-NAME that:
- Initializes `ddp-plist' with command parameters.
- Prepares input (buffer, region, or file) and output buffer.
- Opens a minibuffer for query input with history support."
  (declare (indent defun) (doc-string 2))
  (unless (plistp props)
    (error "ddp: PROPS must be a plist"))
  (cl-destructuring-bind (&key url exec cmd delay mode ansi bind pred method style support)
      props
    (let* ((prefix (concat "ddp-" name))
           (history (intern (concat prefix "-history")))
           (validation-rules
            `((:exec ,exec t "string" stringp)
              (:cmd ,cmd t "string" stringp)
              (:url ,url nil "string" stringp)
              (:delay ,delay nil "number" numberp)
              (:ansi ,ansi nil "boolean" booleanp)
              (:mode ,mode nil "major mode symbol"
               ,(lambda (s) (and (symbolp s)
                                 (string-match-p "-mode$" (symbol-name s)))))
              (:method ,method nil "either window or posframe"
               ,(lambda (s) (memq s '(window posframe))))
              (:style ,style nil "either fixed, fix, or grow"
               ,(lambda (s) (memq s '(fixed fit grow))))
              (:support ,support nil "list of non-empty strings"
               ,(lambda (s)
                  (seq-every-p
                   (lambda (m) (and (stringp m) (not (string-empty-p m))))
                   s)))
              (:bind ,bind nil "alist with element of (key . command)"
               ,(lambda (s)
                  (seq-every-p
                   (pcase-lambda (`(,key . ,command))
                     (and (key-valid-p key) (commandp command)))
                   s)))
              (:pred ,pred nil
               "alist with element of (item . func), item must be either mode, read or write"
               ,(lambda (s)
                  (seq-every-p
                   (pcase-lambda (`(,item . ,func))
                     (and (memq item '(mode read write)) (symbolp func)))
                   s))))))

      ;; check validation
      (dolist (rule validation-rules)
        (pcase-let* ((`(,key ,value ,required ,desc ,pred) rule))
          (if (and required (null value))
              (cl-assert value nil "%s: %s is required" prefix key)
            (when value
              (cl-assert (funcall pred value) nil "%s: %s must be %s" prefix key desc)))))

      `(progn
         (defvar ,history nil
           ,(concat "History list for " name " queries."))

         (defun ,(intern prefix) ()
           ,docstring
           (interactive)
           (unless (executable-find ,exec)
             (error "%s executable not found, see %s" ,exec ,url))
           (setq ddp-plist
                 (list :exec ,exec
                       :cmd ,cmd
                       :ansi ,ansi
                       :mode ',mode
                       :support ',support
                       :delay (or ,delay ddp-debounce-delay)
                       :style (or ',style ddp-display-style)
                       :bind ',bind
                       :pred ',pred
                       :output (get-buffer-create ,(concat "*" prefix "-output*"))
                       :history ',history
                       :win-conf (current-window-configuration)
                       :buffer (current-buffer)
                       :prefix ,prefix))

           ;; prepare output display, setup :method
           (if (and (eq (or ',method ddp-display-method) 'posframe)
                    (ddp--posframe-available))
               (ddp--put :method 'posframe)
             (ddp--put :method 'window))
           (ddp--put :cache-height (car ddp-height-range))

           ;; prepare the input source, setup :file :source :temp
           (let (file source temp)
             (if current-prefix-arg
                 (progn
                   (setq file (read-file-name "Select: " nil nil t))
                   (setq source (file-name-nondirectory file)))
               (setq file (buffer-file-name))
               (setq source (concat (buffer-name) (and (use-region-p) " (region)")))
               (when (or (not file) (use-region-p) (buffer-modified-p))
                 (setq temp (make-temp-file (concat ,prefix "-input")))
                 (write-region (and (use-region-p) (region-beginning))
                               (and (use-region-p) (region-end))
                               temp nil 'silent)))
             (ddp--put :file (and file (expand-file-name file)))
             (ddp--put :source source)
             (ddp--put :temp temp))

           ;; prepare format parser, setup :read and :write if needed
           (ddp-bind (cmd pred support)
             (cl-flet* ((legal-p (str) (and (stringp str) (member str support) str))
                        (call-pred (f) (and (functionp f) (funcall f)))
                        (fselect (k) (completing-read (format "Select %S format:" k)
                                                      support)))
               (when (string-match-p "%r" cmd)
                 (ddp--put :read
                           (or (legal-p (call-pred (alist-get 'read pred)))
                               (legal-p (ddp--default-format-pred))
                               (fselect :read))))
               (when (string-match-p "%w" cmd)
                 (ddp--put :write
                           (or (legal-p (call-pred (alist-get 'write pred)))
                               (ddp--get :read)
                               (legal-p (ddp--default-format-pred))
                               (fselect :write))))))

           ;; prepare output buffer, setup :mode
           (with-current-buffer (ddp--get :output)
             (add-hook 'after-change-major-mode-hook #'ddp--major-mode-setup nil t)
             (when (eq (ddp--get :method) 'posframe)
               (add-hook 'move-frame-functions #'ddp--resize-posframe))
             (let ((inhibit-read-only t))
               (erase-buffer)
               (condition-case nil
                   (funcall (if (or ,ansi (null ',mode)) 'fundamental-mode ',mode))
                 (error (funcall 'fundamental-mode)
                        (ddp--put :mode nil))))
             (read-only-mode))

           ;; prepare init status
           (ddp--refresh-header 'waiting)

           (minibuffer-with-setup-hook
               #'ddp--start-setup
             (read-string (format "[%s] query: " ,prefix) nil ',history)))))))


;;; Methods

(defun ddp--get (prop)
  "Return the value of PROP from `ddp-plist'."
  (plist-get ddp-plist prop))

(defun ddp--put (prop val)
  "Set PROP to VAL in `ddp-plist' and return the updated plist."
  (setq ddp-plist (plist-put ddp-plist prop val)))

(defun ddp--build-cmd (&optional header)
  "Build the command list for the ddp process.

Returns a list of strings by substituting placeholders in :cmd from
`ddp-plist' value.
When HEADER is non-nil, do not substitute %f."
  (ddp-bind (exec cmd temp file query cache-query read write)
    (let ((spec `((?c . ,exec)
                  (?r . ,(or read ""))
                  (?w . ,(or write ""))
                  (?q . ,(if header (concat "'" cache-query "'") (or query "")))
                  (?f . ,(if header "%%f" (or temp file))))))
      (mapcar (lambda (str) (format-spec str spec))
              (string-split cmd)))))
(put 'ddp--major-mode-setup 'permanent-local-hook t)


;;; Headers

(defun ddp--build-header-segment (label value face &optional no-trailer)
  "Build a string segment for the header line.

Whose element with kind [LABEL]: VALUE
LABEL and VALUE are the strings to display. FACE is applied to VALUE.
If NO-TRAILER is non-nil, do not add '  ' at the end for separation."
  (concat
   (propertize "[" 'face 'font-lock-comment-face)
   label
   (propertize "]: " 'face 'font-lock-comment-face)
   (propertize value 'face face)
   (unless no-trailer "  ")))

(defun ddp--refresh-header (status)
  "Update the header line of the ddp output buffer.
STATUS is a symbol determining the status display."
  (with-current-buffer (ddp--get :output)
    (ddp--put :status status)
    (let* ((name (symbol-name status))
           (status-str (format "%-7s" name))
           (status-face (intern (concat "ddp-" name "-status")))
           (cmd-str (string-join (ddp--build-cmd t) " "))
           (style-str (symbol-name (ddp--get :style))))
      (setq-local header-line-format
                  (mapcar
                   (pcase-lambda (`(,label ,value ,face ,no-trailer))
                     (ddp--build-header-segment label value face no-trailer))
                   `(("Status"  ,status-str ,status-face)
                     ("Source"  ,(ddp--get :source) font-lock-function-name-face)
                     ("Style"   ,style-str font-lock-keyword-face)
                     ("Command" ,cmd-str font-lock-builtin-face t))))
      (force-mode-line-update))))


;;; Display

(defun ddp--posframe-available ()
  "Return non-nil if posframe is supported."
  (and (require 'posframe nil t)
       (posframe-workable-p)))

(defun ddp--popup-posframe (&optional height min-height)
  "Display ddp output in a centered posframe with specified height constraints.

This function shows BUF in a posframe, positioned at the center of the frame,
with a width of 80% of the frame width and a height determined by HEIGHT or
cached height settings. The posframe respects minimum and maximum height limits
from `ddp-height-range'.

Parameters:
- HEIGHT (optional): The desired height in lines; if nil, falls back to
  `:cache-height' from `ddp-plist'.
- MIN-HEIGHT (optional): The minimum height in lines; if nil, defaults to the
  second element (MIN) of `ddp-height-range'.

The maximum height is always set to according of `ddp-height-range'."
  (ddp-bind (output cache-height)
    (posframe-show
     output
     :poshandler #'posframe-poshandler-frame-center
     :width (round (* 0.8 (frame-width)))
     :height (or height cache-height)
     :min-height (or min-height (car ddp-height-range))
     :max-height (cdr ddp-height-range)
     :border-width 2
     :border-color "gray50"
     :cursor nil
     :respect-header-line t
     :lines-truncate t)))

(defun ddp--resize-posframe (frame)
  "Resize ddp posframe when window size change on the FRAME."
  (when-let* ((output (ddp--get :output))
              (posframe (posframe--find-existing-posframe output))
              ((frame-visible-p posframe))
              ((eq (frame-parent posframe) frame)))
    (ddp--popup-posframe)))

(defun ddp--popup-window ()
  "Display ddp output result."
  (ddp-bind (output cache-height)
    (display-buffer
     output
     `((display-buffer-in-side-window)
       (side . bottom)
       (window-height . ,cache-height)
       (dedicated . t)))))


;;; Output

(defun ddp--process-sentinel (proc _event)
  "Handle the completion of process PROC and update the ddp output.

It processes the output from PROC, updates the output buffer, adjusts the
display (window or posframe) based on `ddp-height-range', and caches the
content and query. The header line is refreshed to reflect the process status.

Parameters:
- PROC: The process object that has finished execution.
- _EVENT: The event string (unused), provided by the sentinel mechanism.

Behavior:
- If PROC fails (non-zero exit status), sets the header to \\='error.
- If PROC succeeds but output is empty, sets the header to \\='null.
- If PROC succeeds with non-empty output:
  - Updates the output buffer with the new content, applying ANSI colors or
    fontification if configured.
  - Resizes the display (window or posframe):
    - For \\='fit, adjusts height to content within MIN and MAX.
    - For \\='grow, increases height from cached height up to MAX.
    - For \\='fixed, no resize occurs.
  - Caches the content, query, and current height in `ddp-plist'.
  - Sets the header to \\='succeed.
- Ensures the process buffer is killed after processing."
  (with-current-buffer (process-buffer proc)
    (unwind-protect
        (let* ((finish (zerop (process-exit-status proc)))
               (content (buffer-string)))
          (cond
           ((not finish) (ddp--refresh-header 'error))
           ((and finish (string-empty-p content))
            (ddp--refresh-header 'null))
           (t
            (ddp-bind (cache-content output ansi cache-height style method query pred)
              (unless (string= content cache-content)
                (with-current-buffer output
                  (let* ((inhibit-read-only t))
                    (erase-buffer)
                    (if ansi
                        (setq content (ansi-color-apply content))
                      (when-let* ((f (alist-get 'mode pred)))
                        (ignore-errors
                          (when-let* ((mode (funcall f))
                                      ((not (eq mode major-mode))))
                            (funcall mode)))))
                    (insert "\n" content)
                    (font-lock-ensure))
                  ;; resize display because content changes
                  (unless (eq style 'fixed)
                    (pcase-let* ((`(,min . ,max) ddp-height-range)
                                 (min (if (eq style 'fit) min cache-height)))
                      (pcase method
                        ('window
                         (let ((win (get-buffer-window)))
                           (fit-window-to-buffer win max min)
                           (ddp--put :cache-height (window-height win))))
                        ('posframe
                         (let* ((frame (posframe--find-existing-posframe output))
                                (lines (line-number-at-pos (point-max))))
                           (ddp--popup-posframe lines min)
                           (ddp--put :cache-height (frame-height frame))))))))
                (ddp--put :cache-content content))
              (ddp--put :cache-query query)
              (ddp--refresh-header 'succeed)))))
      (kill-buffer))))

(defun ddp--update-output ()
  "Update output buffer with async result using pre-set parameters."
  (ddp--refresh-header 'running)
  (when-let* ((proc (ddp--get :process))
              ((process-live-p proc)))
    (delete-process proc))
  (with-current-buffer (generate-new-buffer " *ddp-temp-output*")
    (ddp--put :process
              (make-process
               :name (ddp--get :prefix)
               :buffer (current-buffer)
               :command (ddp--build-cmd)
               :sentinel #'ddp--process-sentinel))))

(defun ddp--debounce (&rest _)
  "Set a timer to update output with QUERY after a debounce delay."
  (when (minibufferp nil t)
    ;; ensure output is displaying
    (ddp-bind (output method query timer history delay)
      ;; make sure window is live
      (with-current-buffer output
        (pcase method
          ('window
           (unless (get-buffer-window)
             (ddp--popup-window)))
          ('posframe
           (let* ((posframe (posframe--find-existing-posframe output)))
             (unless (and posframe (frame-visible-p posframe))
               (ddp--popup-posframe))))))
      ;; only refresh when query changed, do not count space
      (when-let* ((q (string-trim (minibuffer-contents-no-properties)))
                  ((not (string= q query))))
        (and timer (cancel-timer timer))
        (ddp--refresh-header 'waiting)
        (ddp--put :query q)
        (unless (string-empty-p q)
          (if (member q (symbol-value history))
              (ddp--update-output)
            (ddp--put :timer
                      (run-with-idle-timer delay nil #'ddp--update-output))))))))

(defun ddp--default-format-pred ()
  "Predicate format for ordinary source."
  ;;TODO fetch mode for files use `get-major-mode-for-file' method ?
  (ddp-bind (file buffer temp)
    (let ((ext (unless temp (file-name-extension file)))
          (mode (buffer-local-value 'major-mode buffer)))
      (cond
       ((or (string= ext "json") (memq mode '(js-json-mode json-ts-mode))) "json")
       ((or (member ext '("yaml" "yml")) (memq mode '(yaml-ts-mode yaml-mode))) "yaml")
       ((or (string= ext "toml") (memq mode '(conf-toml-mode toml-ts-mode))) "toml")
       ((or (string= ext "xml") (memq mode '(nxml-mode))) "xml")
       ((or (string= ext "csv") (memq mode '(csv-mode))) "csv")))))

(defun ddp--exit ()
  "Clean up resources when exiting a ddp command.

Cancels timers, kills processes, closes windows, and deletes temporary files."
  (ddp-bind (timer process output method win-conf temp cache-query history)
    (and timer (cancel-timer timer))
    (and process (delete-process process))
    (when (and temp (file-exists-p temp)) (delete-file temp))
    (when cache-query (add-to-history history cache-query))
    (pcase method
      ('posframe
       (posframe-hide output))
      ('window
       (when-let* ((win (get-buffer-window output)))
         (delete-window win))))
    (set-window-configuration win-conf)))

(defun ddp--major-mode-setup (&rest _)
  "Setup vars and functions when ddp output buffer change major mode."
  (let ((inhibit-message t))
    (setq-local window-min-height (car ddp-height-range))
    (setq-local fit-window-to-buffer-horizontally t)
    (setq-local cursor-in-non-selected-windows nil)
    (setq-local window-resize-pixelwise nil)
    (setq-local frame-resize-pixelwise nil)
    (setq-local left-margin 2)
    (setq-local right-margin 2)
    (display-line-numbers-mode -1)
    (toggle-truncate-lines 1)))

(defun ddp--start-setup ()
  "Set up the minibuffer for ddp query input.

Installs keymap, bindings and hooks for debouncing and cleanup."
  (add-hook 'after-change-functions #'ddp--debounce nil t)
  (add-hook 'minibuffer-exit-hook #'ddp--exit nil t)
  (use-local-map ddp-local-map)
  (when-let* ((bindings (ddp--get :bind)))
    (mapc (pcase-lambda (`(,key . ,cmd))
            (keymap-local-set key cmd))
          bindings)))


;;; Commands

(defun ddp-copy-output ()
  "Copy the content of the ddp output buffer to the kill ring."
  (interactive nil minibuffer-mode)
  (when-let* (((minibufferp nil t))
              (buf (ddp--get :output))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (kill-new (buffer-string)))))

(defun ddp-save-output ()
  "Save the content of the ddp output buffer to a file."
  (interactive nil minibuffer-mode)
  (when-let* (((minibufferp nil t))
              (buf (ddp--get :output))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (let ((file (read-file-name "Save output to file: ")))
        (write-region (point-min) (point-max) file nil 'quiet)))))

(defun ddp-clear-query ()
  "Clear the current ddp input in the minibuffer."
  (interactive nil minibuffer-mode)
  (when (minibufferp nil t)
    (delete-minibuffer-contents)))

(defun ddp-copy-as-shell-command ()
  "Copy the cmd as shell command to the kill ring."
  (interactive nil minibuffer-mode)
  (when (minibufferp nil t)
    (if (ddp--get :temp)
        (error "ddp: Current source is buffer not file")
      (kill-new (mapconcat #'shell-quote-argument (ddp--build-cmd) " "))
      (message "Copy as shell command finished."))))

(defun ddp-modify-cmd ()
  "Modify cmd string to update output."
  (interactive nil minibuffer-mode)
  (when (minibufferp nil t)
    (when-let* ((new-cmd (read-from-minibuffer "ddp modify cmd: " (ddp--get :cmd))))
      (ddp--put :cmd new-cmd)
      (ddp--update-output))))

(defun ddp-cycle-output-format ()
  "Cycle output format."
  (interactive nil minibuffer-mode)
  (ddp-bind (support cmd write)
    (when (and (minibufferp nil t)
               (string-match-p "%w" cmd)
               support write)
      (when-let* ((idx (seq-position support write))
                  (n-idx (% (1+ idx) (length support))))
        (ddp--put :write (nth n-idx support))
        (ddp--update-output)))))

(defun ddp-toggle-display-method ()
  "Toggle display method between window and posframe."
  (interactive nil minibuffer-mode)
  (when (and (minibufferp nil t)
             (ddp--posframe-available))
    (let* ((output (ddp--get :output))
           (win (get-buffer-window output))
           (posframe (posframe--find-existing-posframe output)))
      (if posframe
          (progn
            (posframe-delete-frame output)
            (ddp--popup-window)
            (ddp--put :method 'window))
        (and win (delete-window win))
        (ddp--popup-posframe)
        (ddp--put :method 'posframe)))))


;; Examples

;; for html
(ddp-define-command "htmlq"
  "Parse html using htmlq."
  :url "https://github.com/mgdm/htmlq"
  :exec "htmlq"
  :cmd "%e -f %f -- %q"
  :mode html-mode)

(defun ddp-pup-pred ()
  "Detect major mode for `ddp-pup' query."
  (pcase (ddp--get :query)
    ((pred (string-suffix-p "json{}")) 'js-json-mode)
    ((pred (string-suffix-p "text{}")) 'text-mode)
    (_ 'html-mode)))

(ddp-define-command "pup"
  "Parse html using pup."
  :url "https://github.com/gromgit/pup"
  :exec "pup"
  :cmd "%e -f %f %q"
  :pred ((mode . ddp-pup-pred)))

;; for json, yaml related
(ddp-define-command "jq"
  "Parse json using jq."
  :url "https://github.com/jqlang/jq"
  :exec "jq"
  :cmd "%e -C %q %f"
  :ansi t)

(ddp-define-command "yq"
  "Parse data using yq."
  :url "https://github.com/mikefarah/yq"
  :ansi t
  :exec "yq"
  :cmd "%e -P -C -p %r -o %w %f %q"
  :support ("yaml" "json" "toml" "xml" "tsv" "csv" "props" "lua" "base64"))

(ddp-define-command "dasel"
  "Parse data using dasel."
  :url "https://github.com/TomWright/dasel"
  :ansi t
  :exec "dasel"
  :cmd "%e --colour -f %f -r %r -w %w -s %q"
  :support ("yaml" "json" "toml" "csv" "xml"))

(provide 'ddp)
;;; ddp.el ends here
