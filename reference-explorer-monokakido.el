;;; reference-explorer-monokakido.el --- Monokakido reference provider -*- lexical-binding: t -*-

;;; Commentary:

;; Send Reference Explorer queries to Dictionaries by Monokakido through its
;; documented URL scheme.  The application owns search and presentation; this
;; provider deliberately does not participate in the default provider order.

;;; Code:

(require 'reference-explorer)
(require 'url-util)

(defcustom reference-explorer-monokakido-category nil
  "Optional Dictionaries search category.
Examples include \"ja\", \"en\", and \"en-ja\".  Nil uses the application's
current integrated-search category."
  :type '(choice (const :tag "Application default" nil) string)
  :group 'reference-explorer)

(defcustom reference-explorer-monokakido-scope nil
  "Optional Dictionaries search scope.
Examples include \"headword\", \"idiom\", \"example\", and \"sense\".  Nil
uses the application's current search scope."
  :type '(choice (const :tag "Application default" nil) string)
  :group 'reference-explorer)

(defun reference-explorer-monokakido--url (query)
  "Return the Dictionaries URL for QUERY and configured search options."
  (concat
   "mkdictionaries:///?"
   (url-build-query-string
    (delq nil
          `(("text" ,query)
            ,(when reference-explorer-monokakido-category
               (list "category" reference-explorer-monokakido-category))
            ,(when reference-explorer-monokakido-scope
               (list "scope" reference-explorer-monokakido-scope)))))))

(defun reference-explorer-monokakido-available-p ()
  "Return non-nil when this macOS environment can open URL schemes."
  (and (eq system-type 'darwin) (executable-find "open")))

(defun reference-explorer-monokakido-display (context)
  "Open Dictionaries by Monokakido for reference CONTEXT."
  (unless (reference-explorer-monokakido-available-p)
    (signal 'reference-explorer-provider-unavailable
            '("Dictionaries by Monokakido is unavailable")))
  (let ((status
         (call-process
          "open" nil 0 nil "-u"
          (reference-explorer-monokakido--url
           (reference-explorer-context-query context)))))
    (unless (and (integerp status) (zerop status))
      (signal 'reference-explorer-provider-unavailable
              '("Dictionaries by Monokakido could not be opened"))))
  t)

;;;###autoload
(defun reference-explorer-monokakido-at-point ()
  "Open the region or reference query at point in Dictionaries."
  (interactive)
  (let ((context (reference-explorer-context-at-point)))
    (unless context
      (user-error "No reference query at point"))
    (reference-explorer-run-provider 'monokakido context)))

(reference-explorer-register-provider
 'monokakido
 #'reference-explorer-monokakido-display
 #'reference-explorer-monokakido-available-p)

(provide 'reference-explorer-monokakido)
;;; reference-explorer-monokakido.el ends here
