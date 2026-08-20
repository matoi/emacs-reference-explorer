;;; reference-explorer-provider-macos.el --- macOS reference provider -*- lexical-binding: t -*-

;;; Commentary:

;; Display the system Dictionary definition window at the originating Emacs
;; glyph.  The package's build script installs the native module, which is
;; loaded lazily.

;;; Code:

(require 'reference-explorer)
(require 'subr-x)

(defcustom reference-explorer-provider-macos-module-file
  (expand-file-name
   (concat "site-lisp/reference-explorer/reference-explorer-provider-macos-module"
           (if (boundp 'module-file-suffix) module-file-suffix ".dylib"))
   user-emacs-directory)
  "Native module that presents the macOS Dictionary definition window."
  :type 'file
  :group 'reference-explorer)

(declare-function reference-explorer-provider-macos-show-definition
                  "reference-explorer-provider-macos-module"
                  (text screen-x screen-y))
(declare-function reference-explorer-provider-macos-show-definition-with-font
                  "reference-explorer-provider-macos-module"
                  (text screen-x screen-y font-name font-weight font-size))
(declare-function reference-explorer-provider-macos-show-definition-at-offset
                  "reference-explorer-provider-macos-module"
                  (text utf8-byte-offset screen-x screen-y))
(declare-function reference-explorer-provider-macos-selection-at-offset
                  "reference-explorer-provider-macos-module"
                  (text utf8-byte-offset))
(declare-function reference-explorer-provider-macos-hide-definition
                  "reference-explorer-provider-macos-module" ())

(defun reference-explorer-provider-macos--module-loaded-p ()
  "Return non-nil when all required native module functions are defined."
  (and (fboundp 'reference-explorer-provider-macos-show-definition-with-font)
       (fboundp 'reference-explorer-provider-macos-selection-at-offset)
       (fboundp 'reference-explorer-provider-macos-hide-definition)))

(defun reference-explorer-provider-macos--load-module ()
  "Load the native Dictionary module and return non-nil on success."
  (or (reference-explorer-provider-macos--module-loaded-p)
      (and (eq system-type 'darwin)
           (display-graphic-p)
           (fboundp 'module-load)
           (file-readable-p reference-explorer-provider-macos-module-file)
           (condition-case nil
               (progn
                 (module-load reference-explorer-provider-macos-module-file)
                 (reference-explorer-provider-macos--module-loaded-p))
             (error nil)))))

(defun reference-explorer-provider-macos-available-p ()
  "Return non-nil when the system Dictionary popup can be displayed."
  (reference-explorer-provider-macos--load-module))

(defun reference-explorer-provider-macos--presentation (context)
  "Return CONTEXT's screen baseline and actual font presentation.
The result is ((X . Y) FONT-FAMILY FONT-WEIGHT FONT-SIZE)."
  (let* ((marker (reference-explorer-context-marker context))
         (window (reference-explorer-context-window context))
         (buffer (and (markerp marker) (marker-buffer marker))))
    (when (and buffer
               (window-live-p window)
               (eq (window-buffer window) buffer))
      (with-current-buffer buffer
        (when-let* ((marker-position (marker-position marker))
                    (position
                     (window-absolute-pixel-position
                      marker-position window))
                    (frame (window-frame window))
                    (geometry (frame-geometry frame))
                    (outer-position (alist-get 'outer-position geometry)))
          (let* ((font (font-at marker-position window))
                 (font-info
                  (and font
                       (font-info (font-xlfd-name font) frame)))
                 (ascent
                  (or (and font-info (aref font-info 8))
                      (window-default-line-height window)))
                 (family
                  (format "%s" (or (and font (font-get font :family))
                                    (face-attribute 'default :family frame))))
                 (weight
                  (format "%s" (or (and font (font-get font :weight))
                                    'normal)))
                 (size
                  (float
                   (or (and font-info (aref font-info 2))
                       (and font (font-get font :size))
                       (frame-char-height frame)))))
            (list
             (cons (+ (car outer-position) (car position))
                   (+ (cdr outer-position) (cdr position) ascent))
             family
             weight
             size)))))))

(defun reference-explorer-provider-macos--screen-position (context)
  "Return CONTEXT's glyph baseline in Emacs screen pixel coordinates."
  (car (reference-explorer-provider-macos--presentation context)))

(defun reference-explorer-provider-macos--text-at-origin (context)
  "Return CONTEXT's logical line and UTF-8 byte offset at its origin.
The result is (TEXT . OFFSET).  OFFSET identifies point between the UTF-8
bytes in TEXT; the native provider converts it to the NSString index expected
by macOS Dictionary Services."
  (let* ((marker (reference-explorer-context-marker context))
         (buffer (and (markerp marker) (marker-buffer marker))))
    (when buffer
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (save-excursion
            (goto-char marker)
            (let ((start (line-beginning-position))
                  (end (line-end-position)))
              (cons
               (buffer-substring-no-properties start end)
               (string-bytes
                (buffer-substring-no-properties start (point)))))))))))

(defun reference-explorer-provider-macos--character-offset (text utf8-byte-offset)
  "Convert UTF8-BYTE-OFFSET in TEXT to an Emacs character offset."
  (length
   (decode-coding-string
    (substring (encode-coding-string text 'utf-8) 0 utf8-byte-offset)
    'utf-8)))

(defun reference-explorer-provider-macos--automatic-context (context)
  "Return CONTEXT refined to the Dictionary term and its visible beginning."
  (when-let* ((origin (reference-explorer-provider-macos--text-at-origin context))
              (selection
               (reference-explorer-provider-macos-selection-at-offset
                (car origin) (cdr origin)))
              (term (nth 0 selection))
              (start-byte (nth 1 selection))
              (marker (reference-explorer-context-marker context))
              (buffer (and (markerp marker) (marker-buffer marker))))
    (let ((refined (copy-reference-explorer-context context)))
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (save-excursion
            (goto-char marker)
            (setf (reference-explorer-context-marker refined)
                  (copy-marker
                   (+ (line-beginning-position)
                      (reference-explorer-provider-macos--character-offset
                       (car origin) start-byte)))))))
      (setf (reference-explorer-context-query refined) term
            (reference-explorer-context-automatic refined) nil)
      refined)))

(defun reference-explorer-provider-macos--dismiss-before-command ()
  "Dismiss the current Dictionary popup before passing through a command."
  (remove-hook 'pre-command-hook
               #'reference-explorer-provider-macos--dismiss-before-command)
  (when (fboundp 'reference-explorer-provider-macos-hide-definition)
    (ignore-errors (reference-explorer-provider-macos-hide-definition))))

(defun reference-explorer-provider-macos--arm-dismissal ()
  "Arrange for the current Dictionary popup to close on the next command."
  (remove-hook 'pre-command-hook
               #'reference-explorer-provider-macos--dismiss-before-command)
  (add-hook 'pre-command-hook
            #'reference-explorer-provider-macos--dismiss-before-command))

(defun reference-explorer-provider-macos-display (context)
  "Display CONTEXT's query in the macOS system Dictionary popup."
  (unless (reference-explorer-provider-macos--load-module)
    (signal 'reference-explorer-provider-unavailable
            '("macOS Dictionary module is unavailable")))
  (let* ((display-context
          (if (reference-explorer-context-automatic context)
              (reference-explorer-provider-macos--automatic-context context)
            context))
         (presentation
          (and display-context
               (reference-explorer-provider-macos--presentation display-context))))
    (unless presentation
      (signal 'reference-explorer-provider-unavailable
              '("Reference point is not visible in its source window")))
    (pcase-let
        ((`((,x . ,y) ,font-family ,font-weight ,font-size) presentation))
      (unless (reference-explorer-provider-macos-show-definition-with-font
               (reference-explorer-context-query display-context)
               x y font-family font-weight font-size)
        (signal 'reference-explorer-provider-unavailable
                '("macOS Dictionary could not display its definition window"))))
    (reference-explorer-provider-macos--arm-dismissal)
    t))

(reference-explorer-register-provider
 'macos-dictionary
 #'reference-explorer-provider-macos-display
 #'reference-explorer-provider-macos-available-p)

(provide 'reference-explorer-provider-macos)
;;; reference-explorer-provider-macos.el ends here
