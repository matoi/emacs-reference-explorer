;;; reference-explorer-lookup-migemo.el --- Migemo filtering for lookup UI -*- lexical-binding: t -*-

;;; Commentary:

;; Optional extension of `reference-explorer-lookup' for hosts that have
;; already configured Migemo and Orderless.  Loading this file installs a
;; converted-mode completion style; neither the provider dispatcher nor the
;; lookup UI loads it automatically.

;;; Code:

(require 'reference-explorer-lookup)
(require 'migemo)
(require 'orderless)

(defcustom reference-explorer-lookup-migemo-orderless-matching-styles
  '(orderless-prefixes orderless-flex)
  "Orderless matchers tried after the Migemo matcher."
  :type '(repeat function)
  :group 'reference-explorer-lookup)

(defun reference-explorer-lookup-migemo-orderless-regexp (component)
  "Return a Migemo regular expression for Orderless COMPONENT."
  (let ((pattern (migemo-get-pattern component)))
    (condition-case nil
        (progn (string-match-p pattern "") pattern)
      (invalid-regexp nil))))

(orderless-define-completion-style reference-explorer-lookup-migemo-orderless
  (orderless-matching-styles
   (cons 'reference-explorer-lookup-migemo-orderless-regexp
         reference-explorer-lookup-migemo-orderless-matching-styles)))

(setq reference-explorer-lookup-converted-completion-style
      'reference-explorer-lookup-migemo-orderless)

(provide 'reference-explorer-lookup-migemo)
;;; reference-explorer-lookup-migemo.el ends here
