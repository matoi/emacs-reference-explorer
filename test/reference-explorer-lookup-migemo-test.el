;;; reference-explorer-lookup-migemo-test.el --- Lookup Migemo tests -*- lexical-binding: t -*-

(require 'ert)

(ert-deftest reference-explorer-lookup-migemo-selects-its-style ()
  (unless (and (require 'migemo nil t) (require 'orderless nil t))
    (ert-skip "Migemo or Orderless is unavailable"))
  (require 'reference-explorer-lookup-migemo)
  (should (eq reference-explorer-lookup-converted-completion-style
              'reference-explorer-lookup-migemo-orderless)))

(provide 'reference-explorer-lookup-migemo-test)
;;; reference-explorer-lookup-migemo-test.el ends here
