;;; reference-explorer-source-lookup-migemo.el --- Migemo filtering for lookup UI -*- lexical-binding: t -*-

;;; Commentary:

;; Optional extension of `reference-explorer-source-lookup' for hosts that have
;; already configured Migemo and Orderless.  Loading this file installs a
;; converted-mode completion style; neither the provider dispatcher nor the
;; lookup UI loads it automatically.

;;; Code:

(require 'reference-explorer-source-lookup)
(require 'migemo)
(require 'orderless)

(defcustom reference-explorer-source-lookup-migemo-orderless-matching-styles
  '(orderless-prefixes orderless-flex)
  "Orderless matchers tried after the Migemo matcher."
  :type '(repeat function)
  :group 'reference-explorer-source-lookup)

(defun reference-explorer-source-lookup-migemo-orderless-regexp (component)
  "Return a Migemo regular expression for Orderless COMPONENT."
  (let ((pattern (migemo-get-pattern component)))
    (condition-case nil
        (progn (string-match-p pattern "") pattern)
      (invalid-regexp nil))))

(orderless-define-completion-style reference-explorer-source-lookup-migemo-orderless
  (orderless-matching-styles
   (cons 'reference-explorer-source-lookup-migemo-orderless-regexp
         reference-explorer-source-lookup-migemo-orderless-matching-styles)))

(setq reference-explorer-source-lookup-converted-completion-style
      'reference-explorer-source-lookup-migemo-orderless)

(provide 'reference-explorer-source-lookup-migemo)
;;; reference-explorer-source-lookup-migemo.el ends here
