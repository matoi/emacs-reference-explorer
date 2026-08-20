;;; reference-explorer-source-lookup-migemo-test.el --- Lookup Migemo tests -*- lexical-binding: t -*-

(require 'ert)

(ert-deftest reference-explorer-source-lookup-migemo-selects-its-style ()
  (unless (and (require 'migemo nil t) (require 'orderless nil t))
    (ert-skip "Migemo or Orderless is unavailable"))
  (require 'reference-explorer-source-lookup-migemo)
  (should (eq reference-explorer-source-lookup-converted-completion-style
              'reference-explorer-source-lookup-migemo-orderless)))

(provide 'reference-explorer-source-lookup-migemo-test)
;;; reference-explorer-source-lookup-migemo-test.el ends here
