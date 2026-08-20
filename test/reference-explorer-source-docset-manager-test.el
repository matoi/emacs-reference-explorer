;;; reference-explorer-source-docset-manager-test.el --- Docset manager tests -*- lexical-binding: t -*-

(require 'ert)
(require 'reference-explorer-source-docset-manager)

(defconst reference-explorer-source-docset-manager-test--feed
  "<entry>
     <version>3.4.0</version>
     <url>https://example.invalid/Ruby.tgz</url>
     <other-versions>
       <version><name>3.4.0</name></version>
       <version><name>3.3.7</name></version>
       <version><name>3.3.6</name></version>
       <version><name>3.2.9</name></version>
     </other-versions>
   </entry>")

(ert-deftest reference-explorer-source-docset-manager-parses-explicit-selector-kinds ()
  (let ((latest (reference-explorer-source-docset-manager-parse-spec "Ruby"))
        (series (reference-explorer-source-docset-manager-parse-spec "Ruby@3.3.*"))
        (exact (reference-explorer-source-docset-manager-parse-spec "Ruby@3.3.6")))
    (should (eq (reference-explorer-source-docset-spec-policy latest) 'latest))
    (should (eq (reference-explorer-source-docset-spec-policy series) 'series))
    (should (equal (reference-explorer-source-docset-spec-selector series) "3.3"))
    (should (equal (reference-explorer-source-docset-manager-spec-string series)
                   "Ruby@3.3.*"))
    (should (eq (reference-explorer-source-docset-spec-policy exact) 'exact))
    (should-error (reference-explorer-source-docset-manager-parse-spec "Ruby@3.*.6")
                  :type 'user-error)
    (should-error (reference-explorer-source-docset-manager-parse-spec "Ruby@../../escape")
                  :type 'user-error)))

(ert-deftest reference-explorer-source-docset-manager-resolves-series-by-feed-order ()
  (let ((reference-explorer-source-docset-manager-fetch-string-function
         (lambda (_url) reference-explorer-source-docset-manager-test--feed)))
    (let ((series (reference-explorer-source-docset-manager-resolve
                   (reference-explorer-source-docset-manager-parse-spec "Ruby@3.3.*")))
          (exact (reference-explorer-source-docset-manager-resolve
                  (reference-explorer-source-docset-manager-parse-spec "Ruby@3.3.6")))
          (latest (reference-explorer-source-docset-manager-resolve
                   (reference-explorer-source-docset-manager-parse-spec "Ruby@latest"))))
      (should (equal (reference-explorer-source-docset-release-version series) "3.3.7"))
      (should (string-match-p
               "/Ruby/3\\.3\\.7/Ruby\\.tgz\\'"
               (reference-explorer-source-docset-release-url series)))
      (should (equal (reference-explorer-source-docset-release-version exact) "3.3.6"))
      (should (equal (reference-explorer-source-docset-release-version latest) "3.4.0"))
      (should (equal (reference-explorer-source-docset-release-url latest)
                     "https://example.invalid/Ruby.tgz")))))

(ert-deftest reference-explorer-source-docset-manager-rejects-unknown-exact-version ()
  (let ((reference-explorer-source-docset-manager-fetch-string-function
         (lambda (_url) reference-explorer-source-docset-manager-test--feed)))
    (should-error
     (reference-explorer-source-docset-manager-resolve
      (reference-explorer-source-docset-manager-parse-spec "Ruby@9.9.9"))
     :type 'user-error)))

(ert-deftest reference-explorer-source-docset-manager-reads-commented-manifest ()
  (let ((file (make-temp-file "docsets-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# managed references\n"
                    "Ruby@3.3.* # local runtime\n"
                    "\nPython@3.12.6\n"))
          (let ((specs (reference-explorer-source-docset-manager-read-manifest file)))
            (should (equal (mapcar #'reference-explorer-source-docset-manager-spec-string specs)
                           '("Ruby@3.3.*" "Python@3.12.6")))))
      (delete-file file))))

(ert-deftest reference-explorer-source-docset-manager-discovers-feed-identifiers ()
  (let ((reference-explorer-source-docset-manager--feed-cache :uninitialized)
        (reference-explorer-source-docset-manager-fetch-string-function
         (lambda (_url)
           "{\"tree\":[
              {\"path\":\"Ruby.xml\",\"type\":\"blob\"},
              {\"path\":\"Python.xml\",\"type\":\"blob\"},
              {\"path\":\"README.md\",\"type\":\"blob\"},
              {\"path\":\"nested/Ignored.xml\",\"type\":\"blob\"}
            ]}")))
    (should (equal (reference-explorer-source-docset-manager-list-feeds)
                   '("Python" "Ruby")))))

(ert-deftest reference-explorer-source-docset-manager-reads-feed-then-version ()
  (let ((reference-explorer-source-docset-manager--feed-cache '("Python" "Ruby"))
        (reference-explorer-source-docset-manager-fetch-string-function
         (lambda (_url) reference-explorer-source-docset-manager-test--feed))
        (answers '("Ruby" "3.3.*"))
        seen)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection &rest _)
                 (push (cons prompt collection) seen)
                 (pop answers))))
      (should (equal (reference-explorer-source-docset-manager-read-spec) "Ruby@3.3.*")))
    (setq seen (nreverse seen))
    (should (equal (cdar seen) '("Python" "Ruby")))
    (should (member "latest" (cdr (cadr seen))))
    (should (member "3.3.*" (cdr (cadr seen))))
    (should (member "3.3.6" (cdr (cadr seen))))))

(defun reference-explorer-source-docset-manager-test--archive (directory)
  "Create and return a minimal docset archive below DIRECTORY."
  (let* ((source (expand-file-name "source" directory))
         (bundle (expand-file-name "Original.docset" source))
         (resources (expand-file-name "Contents/Resources" bundle))
         (documents (expand-file-name "Documents" resources))
         (database-file (expand-file-name "docSet.dsidx" resources))
         (archive (expand-file-name "Ruby.tgz" directory)))
    (make-directory documents t)
    (with-temp-file (expand-file-name "index.html" documents)
      (insert "<html><body>Ruby documentation</body></html>"))
    (let ((database (sqlite-open database-file)))
      (unwind-protect
          (sqlite-execute
           database
           "CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT)")
        (sqlite-close database)))
    (unless (zerop (process-file "tar" nil nil nil
                                 "-czf" archive "-C" source "."))
      (error "Could not create test archive"))
    archive))

(ert-deftest reference-explorer-source-docset-manager-installs-validated-normalized-bundle ()
  (let* ((temporary (make-temp-file "docset-manager-install-" t))
         (install-root (expand-file-name "installed" temporary))
         (archive (reference-explorer-source-docset-manager-test--archive temporary))
         (reference-explorer-source-docset-manager-install-directory install-root)
         (reference-explorer-source-docset-directories (list install-root))
         (reference-explorer-source-docset--cache :uninitialized)
         (reference-explorer-source-docset-manager-fetch-string-function
          (lambda (_url) reference-explorer-source-docset-manager-test--feed))
         (downloads 0)
         (reference-explorer-source-docset-manager-download-function
          (lambda (_url destination)
            (cl-incf downloads)
            (copy-file archive destination t)))
         messages)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest arguments)
                       (push (apply #'format format-string arguments)
                             messages))))
            (reference-explorer-source-docset-manager-install "Ruby@3.3.*"))
          (should (= downloads 1))
          (should (seq-some
                   (lambda (text) (string-match-p "Installed docset" text))
                   messages))
          (should
           (file-directory-p
            (expand-file-name
             "Ruby/Ruby-3.3.7.docset" install-root)))
          (let ((metadata
                 (json-read-file
                  (expand-file-name
                   (concat "Ruby/Ruby-3.3.7.docset/"
                           reference-explorer-source-docset-metadata-file-name)
                   install-root))))
            (should (equal (alist-get 'feed metadata) "Ruby"))
            (should (equal (alist-get 'version metadata) "3.3.7"))
            (should-not (alist-get 'policy metadata)))
          ;; A second selector resolution for the same concrete release must
          ;; reuse its one versioned bundle rather than download a duplicate.
          (reference-explorer-source-docset-manager-install "Ruby@3.3.*")
          (should (= downloads 1)))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-manager-interactive-install-downloads-async ()
  (let* ((temporary (make-temp-file "docset-manager-async-" t))
         (install-root (expand-file-name "installed" temporary))
         (archive (reference-explorer-source-docset-manager-test--archive temporary))
         (reference-explorer-source-docset-manager-install-directory install-root)
         (reference-explorer-source-docset-directories (list install-root))
         (reference-explorer-source-docset--cache :uninitialized)
         (reference-explorer-source-docset-manager-fetch-string-function
          (lambda (_url) reference-explorer-source-docset-manager-test--feed))
         async-called)
    (unwind-protect
        (cl-letf (((symbol-function
                    'reference-explorer-source-docset-manager--download-async)
                   (lambda (_url destination on-success _on-error)
                     (setq async-called t)
                     (copy-file archive destination t)
                     (funcall on-success))))
          (reference-explorer-source-docset-manager-install "Ruby@latest" nil t)
          (should async-called)
          (should
           (file-directory-p
            (expand-file-name
             "Ruby/Ruby-3.4.0.docset" install-root))))
      (delete-directory temporary t))))

(ert-deftest reference-explorer-source-docset-manager-formats-download-sizes ()
  (should (equal (reference-explorer-source-docset-manager--format-byte-size 512)
                 "512 bytes"))
  (should (equal (reference-explorer-source-docset-manager--format-byte-size 2048)
                 "2.0 KiB"))
  (should (equal (reference-explorer-source-docset-manager--format-byte-size 1572864)
                 "1.5 MiB")))

(ert-deftest reference-explorer-source-docset-manager-saves-asynchronous-response-body ()
  (let ((response (generate-new-buffer " *docset-response*"))
        (destination (make-temp-file "docset-response-"))
        succeeded failure)
    (unwind-protect
        (progn
          (with-current-buffer response
            (set-buffer-multibyte nil)
            ;; `url-retrieve' normalizes response line endings in its buffer.
            (insert "Content-Type: application/octet-stream\n"
                    "Content-Length: 7\n\n"
                    "archive")
            (reference-explorer-source-docset-manager--download-async-callback
             nil destination
             (lambda () (setq succeeded t))
             (lambda (error-data) (setq failure error-data))))
          (should succeeded)
          (should-not failure)
          (should-not (buffer-live-p response))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally destination)
            (should (equal (buffer-string) "archive"))))
      (when (buffer-live-p response) (kill-buffer response))
      (when (file-exists-p destination) (delete-file destination)))))

(provide 'reference-explorer-source-docset-manager-test)
;;; reference-explorer-source-docset-manager-test.el ends here
