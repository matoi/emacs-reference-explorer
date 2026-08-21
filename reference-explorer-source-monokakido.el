;;; reference-explorer-source-monokakido.el --- Monokakido reference source -*- lexical-binding: t -*-

;;; Commentary:

;; Send Reference Explorer queries to Dictionaries by Monokakido through its
;; documented URL scheme.  The application owns search and presentation; this
;; source reports delegated completion because the application owns both
;; retrieval and presentation.  It is not in the default source chain.

;;; Code:

(require 'reference-explorer-source)
(require 'url-util)

(defcustom reference-explorer-source-monokakido-category nil
  "Optional Dictionaries search category.
Examples include \"ja\", \"en\", and \"en-ja\".  Nil uses the application's
current integrated-search category."
  :type '(choice (const :tag "Application default" nil) string)
  :group 'reference-explorer)

(defcustom reference-explorer-source-monokakido-scope nil
  "Optional Dictionaries search scope.
Examples include \"headword\", \"idiom\", \"example\", and \"sense\".  Nil
uses the application's current search scope."
  :type '(choice (const :tag "Application default" nil) string)
  :group 'reference-explorer)

(defun reference-explorer-source-monokakido--url (query)
  "Return the Dictionaries URL for QUERY and configured search options."
  (concat
   "mkdictionaries:///?"
   (url-build-query-string
    (delq nil
          `(("text" ,query)
            ,(when reference-explorer-source-monokakido-category
               (list "category" reference-explorer-source-monokakido-category))
            ,(when reference-explorer-source-monokakido-scope
               (list "scope" reference-explorer-source-monokakido-scope)))))))

(defun reference-explorer-source-monokakido-available-p (&optional _context)
  "Return non-nil when this macOS environment can open URL schemes."
  (and (eq system-type 'darwin) (executable-find "open")))

(defun reference-explorer-source-monokakido-search (query _context complete)
  "Open QUERY in Dictionaries and report delegated completion to COMPLETE."
  (unless (reference-explorer-source-monokakido-available-p)
    (signal 'reference-explorer-source-unavailable
            '("Dictionaries by Monokakido is unavailable")))
  (let ((status
         (call-process
          "open" nil 0 nil "-u"
          (reference-explorer-source-monokakido--url query))))
    (unless (and (integerp status) (zerop status))
      (signal 'reference-explorer-source-unavailable
              '("Dictionaries by Monokakido could not be opened"))))
  (funcall complete
           (reference-explorer-search-outcome-create
            :status 'delegated :value 'monokakido)))

;;;###autoload
(defun reference-explorer-source-monokakido-at-point ()
  "Open the region or reference phrase at point in Dictionaries."
  (interactive)
  (let ((context (reference-explorer-context-at-point)))
    (unless context
      (user-error "No reference phrase at point"))
    (reference-explorer-run-source 'monokakido context)))

(reference-explorer-register-source
 'monokakido
 :title "Dictionaries by Monokakido"
 :search #'reference-explorer-source-monokakido-search
 :available-p #'reference-explorer-source-monokakido-available-p)

(provide 'reference-explorer-source-monokakido)
;;; reference-explorer-source-monokakido.el ends here
