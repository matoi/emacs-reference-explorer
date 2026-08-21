;;; reference-explorer-source-macos.el --- macOS Dictionary source -*- lexical-binding: t -*-

;;; Commentary:

;; Display the system Dictionary definition window at the originating Emacs
;; glyph.  The package's build script installs the native module, which is
;; loaded lazily.

;;; Code:

(require 'reference-explorer-source)
(require 'subr-x)

(defcustom reference-explorer-source-macos-module-file
  (expand-file-name
   (concat "site-lisp/reference-explorer/reference-explorer-source-macos-module"
           (if (boundp 'module-file-suffix) module-file-suffix ".dylib"))
   user-emacs-directory)
  "Native module that presents the macOS Dictionary definition window."
  :type 'file
  :group 'reference-explorer)

(declare-function reference-explorer-source-macos-show-definition
                  "reference-explorer-source-macos-module"
                  (text screen-x screen-y))
(declare-function reference-explorer-source-macos-show-definition-with-font
                  "reference-explorer-source-macos-module"
                  (text screen-x screen-y font-name font-weight font-size))
(declare-function reference-explorer-source-macos-show-definition-at-offset
                  "reference-explorer-source-macos-module"
                  (text utf8-byte-offset screen-x screen-y))
(declare-function reference-explorer-source-macos-selection-at-offset
                  "reference-explorer-source-macos-module"
                  (text utf8-byte-offset))
(declare-function reference-explorer-source-macos-hide-definition
                  "reference-explorer-source-macos-module" ())

(defun reference-explorer-source-macos--module-loaded-p ()
  "Return non-nil when all required native module functions are defined."
  (and (fboundp 'reference-explorer-source-macos-show-definition-with-font)
       (fboundp 'reference-explorer-source-macos-selection-at-offset)
       (fboundp 'reference-explorer-source-macos-hide-definition)))

(defun reference-explorer-source-macos--load-module ()
  "Load the native Dictionary module and return non-nil on success."
  (or (reference-explorer-source-macos--module-loaded-p)
      (and (eq system-type 'darwin)
           (display-graphic-p)
           (fboundp 'module-load)
           (file-readable-p reference-explorer-source-macos-module-file)
           (condition-case nil
               (progn
                 (module-load reference-explorer-source-macos-module-file)
                 (reference-explorer-source-macos--module-loaded-p))
             (error nil)))))

(defun reference-explorer-source-macos-available-p (&optional _context)
  "Return non-nil when the system Dictionary popup can be displayed."
  (reference-explorer-source-macos--load-module))

(defun reference-explorer-source-macos--presentation (context)
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

(defun reference-explorer-source-macos--screen-position (context)
  "Return CONTEXT's glyph baseline in Emacs screen pixel coordinates."
  (car (reference-explorer-source-macos--presentation context)))

(defun reference-explorer-source-macos--text-at-origin (context)
  "Return CONTEXT's logical line and UTF-8 byte offset at its origin.
The result is (TEXT . OFFSET).  OFFSET identifies point between the UTF-8
bytes in TEXT; the native module converts it to the NSString index expected
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

(defun reference-explorer-source-macos--character-offset (text utf8-byte-offset)
  "Convert UTF8-BYTE-OFFSET in TEXT to an Emacs character offset."
  (length
   (decode-coding-string
    (substring (encode-coding-string text 'utf-8) 0 utf8-byte-offset)
    'utf-8)))

(defun reference-explorer-source-macos--automatic-context (context)
  "Return CONTEXT refined to the Dictionary term and its visible beginning."
  (when-let* ((origin (reference-explorer-source-macos--text-at-origin context))
              (selection
               (reference-explorer-source-macos-selection-at-offset
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
                      (reference-explorer-source-macos--character-offset
                       (car origin) start-byte)))))))
      (setf (reference-explorer-context-query refined) term
            (reference-explorer-context-automatic refined) nil)
      refined)))

(defun reference-explorer-source-macos--dismiss-before-command ()
  "Dismiss the current Dictionary popup before passing through a command."
  (remove-hook 'pre-command-hook
               #'reference-explorer-source-macos--dismiss-before-command)
  (when (fboundp 'reference-explorer-source-macos-hide-definition)
    (ignore-errors (reference-explorer-source-macos-hide-definition))))

(defun reference-explorer-source-macos--arm-dismissal ()
  "Arrange for the current Dictionary popup to close on the next command."
  (remove-hook 'pre-command-hook
               #'reference-explorer-source-macos--dismiss-before-command)
  (add-hook 'pre-command-hook
            #'reference-explorer-source-macos--dismiss-before-command))

(defun reference-explorer-source-macos-display (context)
  "Display CONTEXT's query in the macOS system Dictionary popup."
  (unless (reference-explorer-source-macos--load-module)
    (signal 'reference-explorer-source-unavailable
            '("macOS Dictionary module is unavailable")))
  (let* ((display-context
          (if (reference-explorer-context-automatic context)
              (reference-explorer-source-macos--automatic-context context)
            context))
         (presentation
          (and display-context
               (reference-explorer-source-macos--presentation display-context))))
    (unless presentation
      (signal 'reference-explorer-source-unavailable
              '("Reference point is not visible in its source window")))
    (pcase-let
        ((`((,x . ,y) ,font-family ,font-weight ,font-size) presentation))
      (unless (reference-explorer-source-macos-show-definition-with-font
               (reference-explorer-context-query display-context)
               x y font-family font-weight font-size)
        (signal 'reference-explorer-source-unavailable
                '("macOS Dictionary could not display its definition window"))))
    (reference-explorer-source-macos--arm-dismissal)
    t))

(defun reference-explorer-source-macos-search (_query context complete)
  "Display CONTEXT with Dictionary Services and call COMPLETE."
  (reference-explorer-source-macos-display context)
  (funcall complete
           (reference-explorer-search-outcome-create
            :status 'delegated :value 'macos-dictionary)))

(reference-explorer-register-source
 'macos-dictionary
 :title "macOS Dictionary"
 :search #'reference-explorer-source-macos-search
 :available-p #'reference-explorer-source-macos-available-p)

(provide 'reference-explorer-source-macos)
;;; reference-explorer-source-macos.el ends here
