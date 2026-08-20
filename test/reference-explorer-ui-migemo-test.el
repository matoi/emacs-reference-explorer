;;; reference-explorer-ui-migemo-test.el --- Reference UI Migemo tests -*- lexical-binding: t -*-

(require 'ert)

(ert-deftest reference-explorer-ui-migemo-selects-its-style ()
  (unless (and (require 'migemo nil t) (require 'orderless nil t))
    (ert-skip "Migemo or Orderless is unavailable"))
  (require 'reference-explorer-ui-migemo)
  (should (eq reference-explorer-ui-converted-completion-style
              'reference-explorer-ui-migemo-orderless)))

(provide 'reference-explorer-ui-migemo-test)
;;; reference-explorer-ui-migemo-test.el ends here
