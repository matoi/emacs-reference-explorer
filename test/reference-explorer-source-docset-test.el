;;; reference-explorer-source-docset-test.el --- Tests for local docsets -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source-docset)

(defun reference-explorer-source-docset-test--create (directory name rows)
  "Create docset NAME under DIRECTORY with search ROWS."
  (let* ((root (expand-file-name (concat name ".docset") directory))
         (resources (expand-file-name "Contents/Resources" root))
         (documents (expand-file-name "Documents" resources))
         (database-file (expand-file-name "docSet.dsidx" resources)))
    (make-directory documents t)
    (with-temp-file (expand-file-name "index.html" documents)
      (insert "<html><body><p>Introduction</p>"
              "<h1 id=target>Rendered heading</h1>"
              "<p>Rendered body</p></body></html>"))
    (let ((database (sqlite-open database-file)))
      (unwind-protect
          (progn
            (sqlite-execute
             database
             "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)")
            (dolist (row rows)
              (sqlite-execute
               database
               "INSERT INTO searchIndex(name, type, path) VALUES (?, ?, ?)"
               row)))
        (sqlite-close database)))
    root))

(defun reference-explorer-source-docset-test--create-zdash (directory name)
  "Create a minimal ZDash docset NAME under DIRECTORY."
  (let* ((root (reference-explorer-source-docset-test--create directory name nil))
         (database-file
          (expand-file-name "Contents/Resources/docSet.dsidx" root))
         (database (sqlite-open database-file)))
    (unwind-protect
        (progn
          (sqlite-execute database "DROP TABLE searchIndex")
          (sqlite-execute database
                          "CREATE TABLE ZTOKENTYPE(Z_PK INTEGER, ZTYPENAME TEXT)")
          (sqlite-execute database
                          "CREATE TABLE ZTOKEN(Z_PK INTEGER, ZTOKENNAME TEXT, ZTOKENTYPE INTEGER)")
          (sqlite-execute database
                          "CREATE TABLE ZFILEPATH(Z_PK INTEGER, ZPATH TEXT)")
          (sqlite-execute database
                          "CREATE TABLE ZTOKENMETAINFORMATION(ZTOKEN INTEGER, ZFILE INTEGER, ZANCHOR TEXT)")
          (sqlite-execute database
                          "INSERT INTO ZTOKENTYPE VALUES (1, 'Class')")
          (sqlite-execute database
                          "INSERT INTO ZTOKEN VALUES (1, 'Array', 1)")
          (sqlite-execute database
                          "INSERT INTO ZFILEPATH VALUES (1, 'index.html')")
          (sqlite-execute database
                          "INSERT INTO ZTOKENMETAINFORMATION VALUES (1, 1, 'target')"))
      (sqlite-close database))
    root))

(defun reference-explorer-source-docset-test--write-metadata (root feed version)
  "Record managed FEED and VERSION metadata inside docset ROOT."
  (let ((json-encoding-pretty-print t))
    (with-temp-file
        (expand-file-name reference-explorer-source-docset-metadata-file-name root)
      (insert (json-encode `((feed . ,feed) (version . ,version))) "\n"))))

(ert-deftest reference-explorer-source-docset-selects-installed-versions-by-selector ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-versioned-" t))
         (feed-directory (expand-file-name "Ruby" temporary))
         (reference-explorer-source-docset-directories (list temporary))
         (reference-explorer-source-docset--cache :uninitialized))
    (unwind-protect
        (progn
          (make-directory feed-directory)
          (dolist (version '("3.3.6" "3.3.7" "4.0.6"))
            (let ((root
                   (reference-explorer-source-docset-test--create
                    feed-directory (format "Ruby-%s" version)
                    `((,(format "Ruby-%s" version)
                       "Guide" "index.html")))))
              (reference-explorer-source-docset-test--write-metadata root "Ruby" version)))
          (dolist (case '(("Ruby" . "4.0.6")
                          ("Ruby@latest" . "4.0.6")
                          ("Ruby@3.3.*" . "3.3.7")
                          ("Ruby@3.3.6" . "3.3.6")))
            (let ((reference-explorer-source-docset-mode-alist
                   `(((ruby-mode) . (,(car case))))))
              (should
               (equal
                (reference-explorer-source-docset-version
                 (car (reference-explorer-source-docset-for-mode 'ruby-mode)))
                (cdr case))))))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-warns-once-for-missing-file-mode ()
  (let ((reference-explorer-source-docset-directories nil)
        (reference-explorer-source-docset-mode-alist
         '(((ruby-mode ruby-ts-mode) . ("Ruby@3.3.*"))))
        (reference-explorer-source-docset--cache :uninitialized)
        (reference-explorer-source-docset--warned-missing (make-hash-table :test #'equal))
        warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &optional level _buffer-name)
                 (push (list type message level) warnings))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example.rb"
              major-mode 'ruby-ts-mode)
        (reference-explorer-source-docset-warn-if-missing)
        (reference-explorer-source-docset-warn-if-missing))
      (should (= (length warnings) 1))
      (should (eq (caar warnings) 'reference-explorer-source-docset))
      (should (string-match-p "Ruby@3.3.\\*" (cadar warnings)))
      (should (string-match-p "next source" (cadar warnings))))))

(ert-deftest reference-explorer-source-docset-does-not-warn-when-selector-matches ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-warning-" t))
         (feed-directory (expand-file-name "Ruby" temporary))
         (reference-explorer-source-docset-directories (list temporary))
         (reference-explorer-source-docset-mode-alist
          '(((ruby-mode ruby-ts-mode) . ("Ruby"))))
         (reference-explorer-source-docset--cache :uninitialized)
         warned)
    (unwind-protect
        (progn
          (make-directory feed-directory)
          (let ((root (reference-explorer-source-docset-test--create
                       feed-directory "Ruby-4.0.6" nil)))
            (reference-explorer-source-docset-test--write-metadata root "Ruby" "4.0.6"))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (&rest _) (setq warned t))))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.rb"
                    major-mode 'ruby-ts-mode)
              (reference-explorer-source-docset-warn-if-missing)))
          (should-not warned))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-discovers-and-orders-search-results ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-test-" t))
         (reference-explorer-source-docset-directories (list temporary))
         (reference-explorer-source-docset-mode-alist
          '(((ruby-mode) . ("Ruby" "RubyExtra"))))
         (reference-explorer-source-docset-max-results 20)
         (reference-explorer-source-docset--cache :uninitialized))
    (unwind-protect
        (progn
          (reference-explorer-source-docset-test--create
           temporary "Ruby"
           '(("Array" "Class" "index.html#target")
             ("ArrayLike" "Protocol" "index.html")
             ("Kernel.require" "Method" "index.html")
             ("Bundler.require" "Method" "index.html")
             ("Required gemspec attributes" "Section" "index.html")
             ("A%Literal" "Guide" "index.html")
             ("AXWildcard" "Guide" "index.html")))
          (reference-explorer-source-docset-test--create
           temporary "RubyExtra"
           '(("Array" "Guide" "index.html")
             ("Array methods" "Guide" "index.html")))
          (let ((results (reference-explorer-source-docset-search "Array" 'ruby-mode)))
            (should (equal (mapcar #'reference-explorer-source-docset-result-name results)
                           '("Array" "Array" "ArrayLike" "Array methods")))
            (should
             (equal
              (mapcar (lambda (result)
                        (reference-explorer-source-docset-name
                         (reference-explorer-source-docset-result-docset result)))
                      results)
              '("Ruby" "RubyExtra" "Ruby" "RubyExtra"))))
          (should
           (equal (mapcar #'reference-explorer-source-docset-result-name
                          (reference-explorer-source-docset-search "A%" 'ruby-mode))
                  '("A%Literal")))
          (let ((results (reference-explorer-source-docset-search "require" 'ruby-mode)))
            (should
             (equal (mapcar #'reference-explorer-source-docset-result-name results)
                    '("Kernel.require" "Bundler.require"
                      "Required gemspec attributes")))
            (should
             (equal (mapcar #'reference-explorer-source-docset-result-exact results)
                    '(t t nil)))))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-renders-local-html-with-shr ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-render-" t))
         (root (reference-explorer-source-docset-test--create
                temporary "Ruby"
                '(("Array" "Class" "index.html#target"))))
         (docset (reference-explorer-source-docset--bundle root))
         (result (reference-explorer-source-docset-result-create
                  :name "Array" :type "Class" :path "index.html#target"
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-render-test*"))
          (with-current-buffer buffer
            (should (derived-mode-p 'reference-explorer-source-docset-mode))
            (should (equal reference-explorer-source-docset-current-result result))
            (should (= (point) (point-min)))
            (let ((rendered
                   (replace-regexp-in-string
                    "[[:space:]]+" " "
                    (buffer-substring-no-properties
                     (point-min) (point-max)))))
              (should (string-match-p
                       "Rendered heading .*Rendered body" rendered)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-renders-dash-encoded-anchor-at-point ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-anchor-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (raw-fragment
          "//dash_ref_method%2Di%2Drequire/Method/require/0")
         (docset (reference-explorer-source-docset--bundle root))
         (result (reference-explorer-source-docset-result-create
                  :name "Kernel.require" :type "Method"
                  :path (concat "index.html#" raw-fragment)
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" documents)
            (insert "<html><body><p>Page navigation</p>"
                    "<a name=\"" raw-fragment "\"></a>"
                    "<h2>require(path)</h2>"
                    "<p>Loads the given feature.</p></body></html>"))
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-anchor-test*"))
          (with-current-buffer buffer
            (should (= (point) (point-min)))
            (should-not (string-match-p "Page navigation" (buffer-string)))
            (should
             (string-match-p
              "require(path).*Loads the given feature"
              (replace-regexp-in-string
               "[[:space:]]+" " "
               (buffer-substring-no-properties
                (point-min) (point-max)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-normalizes-dash-path-metadata ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-metadata-path-" t))
         (reference-explorer-source-docset-directories (list temporary))
         (reference-explorer-source-docset-mode-alist '(((ruby-mode) . ("Ruby"))))
         (reference-explorer-source-docset--cache :uninitialized))
    (unwind-protect
        (progn
          (reference-explorer-source-docset-test--create
           temporary "Ruby"
           '(("Gem::Specification" "Section"
              "<dash_entry_menuDescription=Gem::Specification>index.html#target")))
          (let ((result (car (reference-explorer-source-docset-search
                              "Gem::Specification" 'ruby-mode))))
            (should result)
            (should (equal (reference-explorer-source-docset-result-path result)
                           "index.html#target"))
            (should (file-regular-p (reference-explorer-source-docset-result-file result)))))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-renders-only-one-dash-entry ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-section-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (docset (reference-explorer-source-docset--bundle root))
         (fragment "//dash_ref_method-i-require/Method/require/0")
         (result (reference-explorer-source-docset-result-create
                  :name "Kernel.require" :type "Method"
                  :path (concat "index.html#" fragment)
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" documents)
            (insert "<html><body><nav>Page navigation</nav>"
                    "<a class=\"dashAnchor\" name=\"" fragment "\"></a>"
                    "<div class=\"method-detail\"><h3>require(path)</h3>"
                    "<p>Loads the given feature.</p></div>"
                    "<a class=\"dashAnchor\" name=\"next\"></a>"
                    "<div class=\"method-detail\"><h3>require_relative</h3>"
                    "<p>Different entry.</p></div></body></html>"))
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-section-test*"))
          (with-current-buffer buffer
            (let ((rendered (replace-regexp-in-string
                             "[[:space:]]+" " " (buffer-string))))
              (should (string-match-p "require(path)" rendered))
              (should (string-match-p "Loads the given feature" rendered))
              (should-not (string-match-p "Page navigation" rendered))
              (should-not (string-match-p "Different entry" rendered)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-renders-rdoc-description-before-source ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-rdoc-order-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (docset (reference-explorer-source-docset--bundle root))
         (fragment "//dash_ref_method-i-require/Method/require/0")
         (result (reference-explorer-source-docset-result-create
                  :name "Kernel.require" :type "Method"
                  :path (concat "index.html#" fragment)
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" documents)
            (insert "<html><body>"
                    "<a class=\"dashAnchor\" name=\"" fragment "\"></a>"
                    "<div class=\"method-detail\">"
                    "<div class=\"method-header\"><h3>require(path)</h3></div>"
                    "<div class=\"method-controls\"><details><summary>Source</summary></details></div>"
                    "<div class=\"method-source-code\"><pre class=\"ruby\">def require(path)\nend</pre></div>"
                    "<div class=\"method-description\"><p>Loads the given feature.</p></div>"
                    "</div></body></html>"))
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-rdoc-order-test*"))
          (with-current-buffer buffer
            (let* ((rendered (replace-regexp-in-string
                              "[[:space:]]+" " " (buffer-string)))
                   (description (string-match "Loads the given feature" rendered))
                   (source-label (string-match "Source" rendered))
                   (source-code (string-match "def require" rendered)))
              (should description)
              (should source-label)
              (should source-code)
              (should (< description source-label))
              (should (< source-label source-code)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-builds-isolated-styled-html ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-html-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (docset (reference-explorer-source-docset--bundle root))
         (fragment "//dash_ref_method-i-require/Method/require/0")
         (result (reference-explorer-source-docset-result-create
                  :name "Kernel.require" :type "Method"
                  :path (concat "index.html#" fragment)
                  :docset docset :exact t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "index.html" documents)
            (insert "<html><head>"
                    "<link rel=\"stylesheet\" href=\"css/rdoc.css\">"
                    "<script src=\"untrusted.js\"></script>"
                    "</head><body class=\"module has-toc\">"
                    "<nav>Page navigation</nav>"
                    "<a class=\"dashAnchor\" name=\"" fragment "\"></a>"
                    "<div class=\"method-detail\"><h3>require(path)</h3>"
                    "<div class=\"method-description\"><p>Loads a feature.</p></div>"
                    "</div></body></html>"))
          (let ((html (reference-explorer-source-docset-render-html
                       result "html { font-size: 14px; }")))
            (should (string-match-p "reference-explorer-source-docset-entry" html))
            (should (string-match-p "css/rdoc.css" html))
            (should (string-match-p "font-size: 14px" html))
            (should (string-match-p "Loads a feature" html))
            (should (string-match-p "querySelector('.method-source-code')"
                                    html))
            (should-not (string-match-p "&amp;&amp;" html))
            (should-not (string-match-p "Page navigation" html))
            (should-not (string-match-p "untrusted.js" html))))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-renders-alias-target-content ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-alias-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (docset (reference-explorer-source-docset--bundle root))
         (result (reference-explorer-source-docset-result-create
                  :name "ctime" :type "Method"
                  :path "Date.html#method-i-ctime"
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Date.html" documents)
            (insert "<html><body>"
                    "<div id=\"method-i-ctime\" class=\"method-detail\">"
                    "<h3>ctime</h3><div class=\"aliases\">Alias for: "
                    "<a href=\"#method-i-asctime\">asctime</a></div></div>"
                    "<div id=\"method-i-asctime\" class=\"method-detail\">"
                    "<h3>asctime</h3><p>Formats this date.</p></div>"
                    "</body></html>"))
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-alias-test*"))
          (with-current-buffer buffer
            (let ((rendered (replace-regexp-in-string
                             "[[:space:]]+" " " (buffer-string))))
              (should (string-match-p "Alias for: asctime" rendered))
              (should (string-match-p "Alias target" rendered))
              (should (string-match-p "Formats this date" rendered)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-no-fragment-starts-at-article-heading ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-article-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (docset (reference-explorer-source-docset--bundle root))
         (result (reference-explorer-source-docset-result-create
                  :name "Array" :type "Class" :path "Array.html"
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "Array.html" documents)
            (insert "<html><body><main><ol role=\"navigation\">"
                    "<li>Ruby</li><li>Array</li></ol>"
                    "<h1>class Array</h1><p>An ordered collection.</p>"
                    "</main></body></html>"))
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-article-test*"))
          (with-current-buffer buffer
            (let ((rendered (replace-regexp-in-string
                             "[[:space:]]+" " " (buffer-string))))
              (should (string-prefix-p "class Array" rendered))
              (should (string-match-p "An ordered collection" rendered))
              (should-not (string-match-p "Ruby" rendered)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-fontifies-classified-code-blocks ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-code-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (documents (expand-file-name "Contents/Resources/Documents" root))
         (docset (reference-explorer-source-docset--bundle root))
         (result (reference-explorer-source-docset-result-create
                  :name "Example" :type "Guide" :path "example.html"
                  :docset docset :exact t))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "example.html" documents)
            (insert "<html><body><main><h1>Example</h1>"
                    "<pre class=\"ruby\">def example\n  :ok\nend</pre>"
                    "</main></body></html>"))
          (setq buffer (reference-explorer-source-docset-render
                        result " *reference-explorer-source-docset-code-test*"))
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "def")
            (let ((faces (get-text-property (match-beginning 0) 'face)))
              (should (if (listp faces)
                          (memq 'font-lock-keyword-face faces)
                        (eq faces 'font-lock-keyword-face))))
            (should
             (memq 'reference-explorer-source-docset-code-block
                   (ensure-list
                    (get-text-property (match-beginning 0) 'face))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-searches-zdash-schema ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-zdash-" t))
         (reference-explorer-source-docset-directories (list temporary))
         (reference-explorer-source-docset-mode-alist
          '(((emacs-lisp-mode) . ("ZDash"))))
         (reference-explorer-source-docset--cache :uninitialized))
    (unwind-protect
        (progn
          (reference-explorer-source-docset-test--create-zdash temporary "ZDash")
          (let ((result (car (reference-explorer-source-docset-search
                              "Array" 'emacs-lisp-mode))))
            (should (equal (reference-explorer-source-docset-result-name result) "Array"))
            (should (equal (reference-explorer-source-docset-result-path result)
                           "index.html#target"))))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-rejects-path-outside-documents ()
  (let* ((temporary (make-temp-file "reference-explorer-source-docset-safe-" t))
         (root (reference-explorer-source-docset-test--create temporary "Ruby" nil))
         (docset (reference-explorer-source-docset--bundle root))
         (result (reference-explorer-source-docset-result-create
                  :name "Unsafe" :type "Guide" :path "../../Info.plist"
                  :docset docset)))
    (unwind-protect
        (should-not (reference-explorer-source-docset-result-file result))
      (delete-directory temporary t))))

(provide 'reference-explorer-source-docset-test)
;;; reference-explorer-source-docset-test.el ends here
