;; guix-subs: a Guix System VM (Proxmox) that builds what Guix qubes need,
;; serves this store with 'guix publish' (port 8080), and fronts it with
;; nginx on port 80: the store at /, caches of bordeaux and ci at /bordeaux/
;; and /ci/, and the Guix commit of the last good nightly build at
;; /guix-commit. See README.md.
;;
;; Files next to this one: build-qubes.sh, template.scm, packages,
;; beto-ssh.pub (your SSH public key). Install with the stock Guix
;; installer, copy this directory to /etc/guix-subs, then:
;;   sudo -H guix pull && sudo guix system reconfigure /etc/guix-subs/config.scm

(use-modules (gnu) (guix channels))
(use-service-modules base mcron networking shepherd ssh virtualization web)
(use-package-modules version-control)
(define %sudoers-specification
  (plain-file "sudoers" "\
root	ALL=(ALL) ALL
%wheel	ALL=(ALL) ALL
beto	ALL=(ALL) NOPASSWD: ALL
"))

;; nonguix (non-free; e.g. firefox-esr). Introduction from the nonguix
;; README. Not pinned: it follows current Guix, as guix-subs does.
(define %nonguix-channel
  (channel
   (name 'nonguix)
   (url "https://gitlab.com/nonguix/nonguix")
   (branch "master")
   (introduction
    (make-channel-introduction
     "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
     (openpgp-fingerprint
      "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5")))))

(define %qubes-channel
  (channel
   (name 'qubes)
   (url "https://github.com/BetoHydroxyButyrate/qubes-guix")
   (branch "main")
   (introduction
    (make-channel-introduction
     "1101f87885074cb3ac8bddc314f274cfeba84e76"
     (openpgp-fingerprint
      "9765 1FBD E504 F2D1 3DA9  88EB C0E8 4747 0C0B 2F22")))))

(define %beto-channel
  (channel
   (name 'beto)
   (url "https://github.com/BetoHydroxyButyrate/guix-channel")
   (branch "main")
   (introduction
    (make-channel-introduction
     "cef6bf6d5d21e3250242a2b6ea02fd9a6ec791cf"
     (openpgp-fingerprint
      "9765 1FBD E504 F2D1 3DA9  88EB C0E8 4747 0C0B 2F22")))))

;; A caching proxy for the upstream substitute servers, next to guix publish,
;; all on port 80:
;;   http://guix-subs.zepherin.com/           this machine's store (guix publish)
;;   http://guix-subs.zepherin.com/bordeaux/  bordeaux.guix.gnu.org, cached here
;;   http://guix-subs.zepherin.com/ci/        ci.guix.gnu.org, cached here
;; Cached substitutes keep their upstream signatures, so clients need no
;; new key for them (bordeaux's and ci's are authorized by default); only
;; this machine's own builds need its key.
(define (cached-upstream path host)
  (nginx-location-configuration
   (uri path)
   (body (list (string-append "proxy_pass https://" host "/;")
               "proxy_ssl_server_name on;"
               (string-append "proxy_set_header Host " host ";")
               "proxy_http_version 1.1;"
               "proxy_cache guix;"
               ;; Narinfos and nars never change: keep them. A missing
               ;; narinfo (404) may appear later: recheck after 10 minutes.
               "proxy_cache_valid 200 90d;"
               "proxy_cache_valid any 10m;"
               "proxy_cache_lock on;"
               "proxy_cache_use_stale error timeout updating;"
               "proxy_ignore_headers Cache-Control Expires Set-Cookie;"
               "add_header X-Cache-Status $upstream_cache_status;"))))

(define %substitute-cache "/var/cache/nginx/guix")

;; The upstream substitute servers nginx caches, by location.
(define %upstreams
  '(("/bordeaux/" . "bordeaux.guix.gnu.org")
    ("/ci/" . "ci.guix.gnu.org")))

;; nginx resolves the proxy_pass host names once, when it starts, and
;; fails (Shepherd doesn't retry) if one doesn't resolve. At boot, IPv6
;; (router advertisement, with its DNS server) can come up seconds before
;; the IPv4 lease, and nginx asks getaddrinfo with AI_ADDRCONFIG: until
;; there's an IPv4 address, an IPv4-only host (ci) "doesn't exist", though
;; bordeaux (which has IPv6) resolves. So nginx waits for this: done once
;; EVERY upstream host resolves the way nginx asks (up to 2 minutes).
(define wait-for-dns
  (program-file "wait-for-dns"
                #~(begin
                    (define (resolves? host)
                      (false-if-exception
                       (getaddrinfo host "https" AI_ADDRCONFIG)))
                    (define (all-resolve? hosts)
                      (or (null? hosts)
                          (and (resolves? (car hosts))
                               (all-resolve? (cdr hosts)))))
                    (let loop ((i 0))
                      (cond ((all-resolve? '#$(map cdr %upstreams)) (exit 0))
                            ((< i 120) (sleep 1) (loop (+ i 1)))
                            (else (exit 1)))))))

(define dns-ready-service
  (simple-service 'dns-ready shepherd-root-service-type
                  (list (shepherd-service
                         (documentation "Wait until upstream names resolve.")
                         (provision '(dns-ready))
                         (requirement '(networking))
                         (one-shot? #t)
                         (start #~(lambda _
                                    (zero? (system* #$wait-for-dns))))))))

;; Nightly: pull, then build a typical template system and the extra
;; packages, so they're in the store for 'guix publish'.
(define build-job
  #~(job "0 2 * * *"
         (string-append #$(local-file "build-qubes.sh" #:recursive? #t)
                        " >> /var/log/qubes-builds.log 2>&1")))

;; Weekly: drop root's guix generations older than a month and collect
;; garbage until 150 GiB are free. The current builds are GC roots.
(define gc-job
  #~(job "0 4 * * 0"
         "/run/current-system/profile/bin/guix gc --delete-generations=1m -F 150G"))

(operating-system
  (host-name "guix-subs")
  (sudoers-file %sudoers-specification)
  (timezone "Australia/Brisbane")
  (locale "en_AU.utf8")

  ;; Proxmox: VirtIO SCSI single controller, so the disk is /dev/sda.
  (bootloader (bootloader-configuration
               (bootloader grub-bootloader)
               (targets '("/dev/sda"))))
  (file-systems (cons (file-system
                        (device (file-system-label "guix-root"))
                        (mount-point "/")
                        (type "ext4"))
                      %base-file-systems))

  ;; Proxmox serial console (qm set VMID -serial0 socket): boot messages and
  ;; a login on ttyS0, for 'qm terminal VMID' and the xterm.js console.
  ;; %base-services already runs an agetty on the console= device: don't
  ;; add another, or the two fight over ttyS0 (no job control).
  (kernel-arguments (cons "console=ttyS0,115200" %default-kernel-arguments))

  (users (cons (user-account
                (name "beto")
                (group "users")
                (supplementary-groups '("wheel")))
               %base-user-accounts))

  (packages (cons* git %base-packages))

  (services
   (append
    (list (service dhcpcd-service-type)
          (service qemu-guest-agent-service-type)   ; qm guest exec
          (service openssh-service-type
                   (openssh-configuration
                    (password-authentication? #f)
                    (authorized-keys
                     `(("beto" ,(local-file "beto-ssh.pub"))))))
          (service guix-publish-service-type
                   (guix-publish-configuration
                    (host "0.0.0.0")
                    (port 8080)
                    ;; Compress once, in the background, and keep it:
                    ;; requests are served from the cache.
                    (cache "/var/cache/guix/publish")
                    (compression '(("zstd" 19)))
                    (ttl (* 90 24 3600))))
          (service nginx-service-type
                   (nginx-configuration
                    (shepherd-requirement '(dns-ready))
                    (extra-content
                     (string-append
                      "proxy_cache_path " %substitute-cache
                      " levels=1:2 keys_zone=guix:50m inactive=180d"
                      " max_size=1000g use_temp_path=off;"))
                    (server-blocks
                     (list (nginx-server-configuration
                            (listen '("80"))
                            (server-name '("guix-subs.zepherin.com" "_"))
                            (locations
                             (append
                              (map (lambda (u) (cached-upstream (car u) (cdr u)))
                                   %upstreams)
                              (list
                                   ;; The Guix commit of the last good
                                   ;; nightly build (build-qubes.sh).
                                   (nginx-location-configuration
                                    (uri "= /guix-commit")
                                    (body '("alias /var/lib/qubes-builds/guix-commit;"
                                            "default_type text/plain;"
                                            "add_header Cache-Control no-cache;")))
                                   (nginx-location-configuration
                                    (uri "/")
                                    (body '("proxy_pass http://127.0.0.1:8080;")))))))))))
          dns-ready-service
          ;; The cache directory, writable by nginx's workers.
          (simple-service 'substitute-cache-dir activation-service-type
                          #~(begin
                              (for-each (lambda (d)
                                          (unless (file-exists? d) (mkdir d)))
                                        '("/var/cache" "/var/cache/nginx"
                                          #$%substitute-cache))
                              (let ((nginx (getpwnam "nginx")))
                                (chown #$%substitute-cache
                                       (passwd:uid nginx) (passwd:gid nginx)))))
          (simple-service 'qubes-builds mcron-service-type
                          (list build-job gc-job)))
    (modify-services %base-services
      (guix-service-type
       config => (guix-configuration
                  (inherit config)
                  ;; /etc/guix/channels.scm: what root's nightly pull uses.
                  (channels (cons* %qubes-channel %beto-channel %nonguix-channel
                                   %default-channels))
                  ;; nonguix's build farm too: firefox-esr comes as a
                  ;; substitute (hours to build otherwise), and is then
                  ;; served from this store, signed with our key.
                  (substitute-urls
                   (append (guix-configuration-substitute-urls config)
                           '("https://substitutes.nonguix.org")))
                  (authorized-keys
                   (cons (plain-file "nonguix.pub"
                                     "(public-key (ecc (curve Ed25519) (q #C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98#)))")
                         (guix-configuration-authorized-keys config)))
                  ;; 16 vCPUs: 4 builds at a time, 4 cores each.
                  (extra-options '("--max-jobs=4" "--cores=4"))))))))
