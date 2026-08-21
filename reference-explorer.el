;;; reference-explorer.el --- Dictionary and documentation browser -*- lexical-binding: t -*-
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/matoi/emacs-reference-explorer
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Main entry point for Reference Explorer.  Requiring this feature loads the
;; core dispatcher, shared UI, and bundled sources and providers.  Optional
;; integrations such as Lookup and Migemo remain separate.

;;; Code:

(require 'reference-explorer-ui)

(provide 'reference-explorer)
;;; reference-explorer.el ends here
