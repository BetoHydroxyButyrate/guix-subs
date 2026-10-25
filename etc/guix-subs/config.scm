;; guix-subs: a Guix System VM (Proxmox) that builds what Guix qubes need,
;; serves this store with 'guix publish' (port 8080), and fronts it with
;; nginx on port 80: the store at /, caches of bordeaux and ci at /bordeaux/
;; and /ci/, and the channel commits of the last good nightly build at
;; /channel-commits (Guix's alone at /guix-commit). See README.md.
;;
;; Files next to this one: build-qubes.sh, template.scm, packages,
;; beto-ssh.pub (your SSH public key). Install with the stock Guix
;; installer, copy this directory to /etc/guix-subs, then:
;;   sudo -H guix pull && sudo guix system reconfigure /etc/guix-subs/config.scm

(use-modules (gnu) (guix channels))
(use-service-modules base linux mcron networking shepherd ssh virtualization web)
(use-package-modules version-control)

;; The name qubes use for this machine: nginx's server_name, and the
;; certificate's (see README.md, HTTPS).
(define %host-name "guix-subs.zepherin.com")
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
;;   http://HOST/           this machine's store (guix publish)
;;   http://HOST/bordeaux/  bordeaux.guix.gnu.org, cached here
;;   http://HOST/ci/        ci.guix.gnu.org, cached here
;; and the same over https once the Proxmox host has pushed a certificate.
;; Cached substitutes keep their upstream signatures, so clients need no
;; new key for them (bordeaux's and ci's are authorized by default); only
;; this machine's own builds need its key.
;;
;; The upstream's name goes through a variable, so nginx looks it up when a
;; request comes (with the resolver below), not when it loads its
;; configuration: its config check (nginx-init, which waits for nothing)
;; and its start then never depend on DNS. With a literal name, a restart
;; while DNS wasn't up yet (a reconfigure restarting nginx-init and
;; dns-ready at once) failed the check, and nginx stayed down.
(define (cached-upstream path host)
  (nginx-location-configuration
   (uri path)
   (body (list (string-append "set $upstream_host " host ";")
               ;; With a variable, proxy_pass passes the URI as is: strip
               ;; the location's prefix here instead.
               (string-append "rewrite ^" path "(.*)$ /$1 break;")
               "proxy_pass https://$upstream_host;"
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

;; /NAME: /var/lib/qubes-builds/NAME, as plain text, never cached.
(define (published-file name)
  (nginx-location-configuration
   (uri (string-append "= /" name))
   (body (list (string-append "alias /var/lib/qubes-builds/" name ";")
               "default_type text/plain;"
               "add_header Cache-Control no-cache;"))))

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

;; nginx's resolver for the upstreams' names: this machine's DNS servers,
;; from /etc/resolv.conf (DHCP's), as /var/lib/guix-subs/nginx-resolver.conf,
;; which nginx.conf includes. Written at activation (so the file is there
;; for nginx's config check), and again by dns-ready, before nginx starts.
(define %nginx-resolver-file "/var/lib/guix-subs/nginx-resolver.conf")

(define nginx-resolver
  (program-file
   "nginx-resolver"
   #~(begin
       (use-modules (ice-9 rdelim))
       (define (nameservers)
         (or (false-if-exception
              (call-with-input-file "/etc/resolv.conf"
                (lambda (port)
                  (let loop ((acc '()))
                    (let ((line (read-line port)))
                      (if (eof-object? line)
                          (reverse acc)
                          (loop (let ((words (string-tokenize line)))
                                  (if (and (= (length words) 2)
                                           (string=? (car words) "nameserver")
                                           ;; nginx can't use a link-local
                                           ;; address's %zone
                                           (not (string-index (cadr words) #\%)))
                                      (cons (cadr words) acc)
                                      acc)))))))))
             '()))
       (define (address a)               ; IPv6 in brackets
         (if (string-index a #\:) (string-append "[" a "]") a))
       (let ((servers (nameservers))
             (tmp (string-append #$%nginx-resolver-file ".tmp")))
         (unless (file-exists? "/var/lib/guix-subs")
           (mkdir "/var/lib/guix-subs"))
         (call-with-output-file tmp
           (lambda (port)
             (format port "resolver ~a valid=300s ipv6=off;~%"
                     (if (null? servers)
                         "127.0.0.1"     ; none known yet: dns-ready rewrites it
                         (string-join (map address servers) " ")))
             (display "resolver_timeout 10s;\n" port)))
         (rename-file tmp #$%nginx-resolver-file)))))

(define dns-ready-service
  (simple-service 'dns-ready shepherd-root-service-type
                  (list (shepherd-service
                         (documentation "Wait until upstream names resolve.")
                         (provision '(dns-ready))
                         (requirement '(networking))
                         (one-shot? #t)
                         (start #~(lambda _
                                    (and (zero? (system* #$wait-for-dns))
                                         (zero? (system* #$nginx-resolver)))))))))


;; Nightly: pull, then build a typical template system and the extra
;; packages, so they're in the store for 'guix publish'.
(define build-job
  #~(job "0 2 * * *"
         (string-append #$(local-file "build-qubes.sh" #:recursive? #t)
                        " >> /var/log/qubes-builds.log 2>&1")))

;; Every 10 minutes: a new qubes-guix commit is built at once, with the
;; other channels at the published commits (build-qubes.sh --qubes-only);
;; the nightly run moves those.
(define poll-job
  #~(job "*/10 * * * *"
         (string-append #$(local-file "poll-qubes.sh" #:recursive? #t)
                        " " #$(local-file "build-qubes.sh" #:recursive? #t)
                        " >> /var/log/qubes-builds.log 2>&1")))

;; Weekly: drop root's guix generations older than a month and collect
;; garbage until 150 GiB are free. The current builds are GC roots.
(define gc-job
  #~(job "0 4 * * 0"
         "/run/current-system/profile/bin/guix gc --delete-generations=1m -F 150G"))

;; nginx's server: the same locations on port 80 and, with TLS? true, on
;; 443 with the certificate in /etc/guix-subs-tls, which the Proxmox host
;; pushes in (pve/guix-subs-cert, install-cert.sh). Until the first push
;; that's a self-signed placeholder (tls-placeholder below), so nginx can
;; start; port 80 keeps working throughout.
(define %tls-dir "/etc/guix-subs-tls")

(define (substitute-server listen tls?)
  (nginx-server-configuration
   (listen listen)
   (server-name (list %host-name "_"))
   (ssl-certificate (and tls? (string-append %tls-dir "/fullchain.pem")))
   (ssl-certificate-key (and tls? (string-append %tls-dir "/privkey.pem")))
   (locations
    (append
     (map (lambda (u) (cached-upstream (car u) (cdr u)))
          %upstreams)
     (list
      ;; The commits of the last good nightly build (build-qubes.sh): every
      ;; channel's, and Guix's alone.
      (published-file "channel-commits")
      (published-file "guix-commit")
      ;; The key this machine signs its substitutes with (guix publish's),
      ;; for clients to fetch and check by its fingerprint: qubes-guix's
      ;; qg-config, before it authorizes the key in new qubes.
      (nginx-location-configuration
       (uri "= /signing-key.pub")
       (body '("alias /etc/guix/signing-key.pub;"
               "default_type text/plain;"
               "add_header Cache-Control no-cache;")))
      (nginx-location-configuration
       (uri "/")
       (body '("proxy_pass http://127.0.0.1:8080;"))))))))

;; A self-signed certificate in /etc/guix-subs-tls if there's none yet.
(define tls-placeholder
  (simple-service
   'tls-placeholder activation-service-type
   #~(let ((dir #$%tls-dir))
       (unless (file-exists? dir) (mkdir dir))
       (chmod dir #o755)
       (unless (file-exists? (string-append dir "/fullchain.pem"))
         (system* #$(file-append (specification->package "openssl")
                                 "/bin/openssl")
                  "req" "-x509" "-newkey" "rsa:2048" "-nodes" "-days" "3650"
                  "-subj" (string-append "/CN=" #$%host-name)
                  "-keyout" (string-append dir "/privkey.pem")
                  "-out" (string-append dir "/fullchain.pem"))
         (chmod (string-append dir "/privkey.pem") #o600)))))

;; /etc/guix-subs-install-cert: install-cert.sh, with openssl and herd.
(define install-cert
  (program-file
   "guix-subs-install-cert"
   #~(begin
       (setenv "PATH"
               (string-append #$(file-append (specification->package "openssl")
                                             "/bin")
                              ":/run/current-system/profile/bin"
                              ":/run/current-system/profile/sbin"))
       (apply execl #$(local-file "install-cert.sh" #:recursive? #t)
              "install-cert.sh" (cdr (command-line))))))

(define tcp-bbr-service
  (shepherd-service
   (documentation "Use BBR congestion control (and fq) once tcp_bbr is loaded.")
   (provision '(tcp-bbr))
   (requirement '(kernel-module-loader))
   (one-shot? #t)
   (start #~(lambda _
              (define (write-proc file value)
                (call-with-output-file file
                  (lambda (port) (display value port))))
              (write-proc "/proc/sys/net/core/default_qdisc" "fq")
              (write-proc "/proc/sys/net/ipv4/tcp_congestion_control" "bbr")
              #t))))

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
                      " max_size=1000g use_temp_path=off;\n"
                      "include " %nginx-resolver-file ";"))
                    (server-blocks
                     (list (substitute-server '("80") #f)
                           (substitute-server '("443 ssl") #t)))))
          dns-ready-service
          tls-placeholder
          (simple-service 'install-cert etc-service-type
                          (list (list "guix-subs-install-cert" install-cert)))
          ;; The cache directory, writable by nginx's workers.
          (simple-service 'substitute-cache-dir activation-service-type
                          #~(begin
                              (for-each (lambda (d)
                                          (unless (file-exists? d) (mkdir d)))
                                        '("/var/cache" "/var/cache/nginx"
                                          #$%substitute-cache))
                              (let ((nginx (getpwnam "nginx")))
                                (chown #$%substitute-cache
                                       (passwd:uid nginx) (passwd:gid nginx)))
                              (system* #$nginx-resolver)))
          (simple-service 'qubes-builds mcron-service-type
                          (list build-job poll-job gc-job))
          ;; BBR: paced sending. The Qubes CI machine's 1 Gb/s port is
          ;; behind another switch, across a 10 Gb/s LAG; with cubic, 10 Gb/s
          ;; bursts into it lost ~8% of packets and nars reached it at
          ;; 2 MB/s, with BBR ~90 MB/s. Not through sysctl-service-type: its
          ;; service runs before modules can be loaded, so "bbr" isn't there
          ;; yet. tcp_bbr from the module loader, then set it.
          (service kernel-module-loader-service-type '("tcp_bbr"))
          (simple-service 'tcp-bbr shepherd-root-service-type
                          (list tcp-bbr-service)))
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
