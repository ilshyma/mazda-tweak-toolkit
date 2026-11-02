/*
 * Tweaks Manager v2 — Opera 12 / Presto UI
 * Pure DOM overlay, no framework deps. Inline styles (no CSS vars).
 * Shows TWEAKS button in Settings, fullscreen overlay with cards.
 * USB required — won't open without it (fool-proof).
 * Mandatory backup+log sync to USB on every open.
 * Scaled for 7" 800x480 CMU screen.
 */
(function() {
    var TWEAKSD = 'http://127.0.0.1:8035';
    var XHR_TIMEOUT = 30000;

    /* state */
    var overlay = null;
    var btn = null;
    var visible = false;
    var cachedTweaks = null;
    var cachedVer = null;
    var cachedUsb = null;

    /* colors — Opera 12 has no var() */
    var BG = '#0b1120';
    var HDR_BG = '#0f172a';
    var CARD_BG = '#111827';
    var CARD_BD = '#1e293b';
    var GREEN = '#22c55e';
    var YELLOW = '#eab308';
    var CYAN = '#06b6d4';
    var RED = '#ef4444';
    var BLUE = '#38bdf8';
    var TXT = '#e2e8f0';
    var TXT2 = '#94a3b8';
    var TXT3 = '#64748b';
    var BTN_BG = '#1e293b';
    var BTN_BG2 = '#374151';

    function dbg(m) {
        try { window.opera.postError('[tweaks-menu] ' + m); } catch(e) {}
    }

    function setS(el, p) {
        for (var k in p) { if (p.hasOwnProperty(k)) el.style[k] = p[k]; }
    }

    function mkEl(tag, s, t) {
        var el = document.createElement(tag);
        if (s) setS(el, s);
        if (t !== undefined && t !== null) el.textContent = String(t);
        return el;
    }

    function api(method, path, cb) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open(method, TWEAKSD + path, true);
            var done = false;
            var timer = setTimeout(function() {
                if (!done) { done = true; try { xhr.abort(); } catch(e) {} cb(0, null); }
            }, XHR_TIMEOUT);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4 && !done) {
                    done = true;
                    clearTimeout(timer);
                    var d = null;
                    try { d = JSON.parse(xhr.responseText); } catch(e) {}
                    cb(xhr.status, d);
                }
            };
            xhr.onerror = function() {
                if (!done) { done = true; clearTimeout(timer); cb(0, null); }
            };
            xhr.send();
        } catch(e) { cb(0, null); }
    }

    /* ── Touch scrolling with inertia (CMU has no native scroll) ──── */
    var scrollState = null;
    var inertiaTimer = null;

    function stopInertia() {
        if (inertiaTimer) { clearInterval(inertiaTimer); inertiaTimer = null; }
    }

    function enableScroll(container) {
        container.onmousedown = function(e) {
            var t = e.target || e.srcElement;
            while (t && t !== container) {
                if (t.getAttribute && t.getAttribute('data-action')) return;
                t = t.parentNode;
            }
            stopInertia();
            scrollState = { el: container, startY: e.clientY, startScroll: container.scrollTop, lastT: 0, prevY: e.clientY, velocity: 0 };
        };
        container.onmousemove = function(e) {
            if (!scrollState) return;
            var now = (new Date()).getTime();
            if (now - scrollState.lastT < 32) return;
            var dt = now - scrollState.lastT;
            scrollState.lastT = now;
            var dy = (scrollState.startY - e.clientY) * 1.5;
            scrollState.el.scrollTop = scrollState.startScroll + dy;
            scrollState.velocity = (scrollState.prevY - e.clientY) / (dt || 1);
            scrollState.prevY = e.clientY;
        };
        function endDrag() {
            if (!scrollState) return;
            var v = scrollState.velocity * 1.5 * 16;
            var el = scrollState.el;
            scrollState = null;
            if (Math.abs(v) < 2) return;
            inertiaTimer = setInterval(function() {
                v *= 0.92;
                if (Math.abs(v) < 1) { stopInertia(); return; }
                el.scrollTop += v;
            }, 32);
        }
        container.onmouseup = endDrag;
        container.onmouseout = function(e) {
            if (scrollState && (!e.relatedTarget || !container.contains(e.relatedTarget)))
                endDrag();
        };
    }

    /* ── Settings button (bottom-right, shown only in Settings apps) ─ */
    function createButton() {
        if (btn) return;
        if (!document.body) return;

        btn = document.createElement('div');
        btn.id = 'tweaks-settings-btn';
        setS(btn, {
            position: 'fixed', bottom: '12px', left: '12px',
            width: '48px', height: '48px',
            padding: '0', textAlign: 'center',
            background: '#b91c1c', borderRadius: '50%',
            zIndex: '99998', cursor: 'pointer',
            display: 'none',
            border: '1px solid #ef4444'
        });
        btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="38" height="38" style="margin-top:5px">'
            + '<rect x="5" y="5" width="14" height="14" rx="2" fill="none" stroke="#fff" stroke-width="1.8"/>'
            + '<text x="12" y="15" text-anchor="middle" fill="#fff" font-size="8" font-weight="bold" font-family="sans-serif">T</text>'
            + '<line x1="8" y1="3" x2="8" y2="5" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="12" y1="3" x2="12" y2="5" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="16" y1="3" x2="16" y2="5" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="8" y1="19" x2="8" y2="21" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="12" y1="19" x2="12" y2="21" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="16" y1="19" x2="16" y2="21" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="3" y1="8" x2="5" y2="8" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="3" y1="12" x2="5" y2="12" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="3" y1="16" x2="5" y2="16" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="19" y1="8" x2="21" y2="8" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="19" y1="12" x2="21" y2="12" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '<line x1="19" y1="16" x2="21" y2="16" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>'
            + '</svg>';
        btn.onclick = function() { showUI(); };
        document.body.appendChild(btn);
        dbg('button created');
    }

    function checkVisibility() {
        try {
            var app = window.framework && window.framework._currentAppUiaId;
            var show = (app === 'syssettings' || app === 'vehsettings');
            if (show && !visible) {
                if (btn) btn.style.display = 'block';
                visible = true;
            } else if (!show && visible) {
                if (btn) btn.style.display = 'none';
                if (overlay) overlay.style.display = 'none';
                visible = false;
            }
        } catch(e) {}
    }

    /* ── Header ────────────────────────────────────────────────────── */
    function buildHeader() {
        var hdr = mkEl('div', {
            position: 'absolute', top: '0', left: '0', right: '0', height: '72px',
            background: HDR_BG, borderBottom: '1px solid ' + CARD_BD,
            padding: '0 24px', zIndex: '2'
        });

        var title = mkEl('span', {
            fontSize: '22px', fontWeight: 'bold', color: TXT,
            letterSpacing: '3px', verticalAlign: 'middle',
            lineHeight: '72px'
        }, 'TWEAKS MANAGER');
        hdr.appendChild(title);

        var verBadge = mkEl('span', {
            display: 'inline-block', verticalAlign: 'middle',
            padding: '3px 12px', marginLeft: '12px',
            background: BTN_BG, borderRadius: '12px',
            fontSize: '16px', color: TXT3, border: '1px solid ' + BTN_BG2
        });
        verBadge.id = 'tm-ver-badge';
        verBadge.textContent = '...';
        hdr.appendChild(verBadge);

        var usbStatus = mkEl('span', {
            display: 'inline-block', verticalAlign: 'middle',
            marginLeft: '18px', fontSize: '16px', color: TXT3,
            lineHeight: '72px'
        });
        usbStatus.id = 'tm-usb-status';
        hdr.appendChild(usbStatus);

        var close = mkEl('div', {
            position: 'absolute', right: '18px', top: '14px',
            padding: '10px 22px', cursor: 'pointer',
            background: BTN_BG, borderRadius: '10px',
            color: TXT2, fontSize: '18px', fontWeight: 'bold',
            border: '1px solid ' + CARD_BD
        });
        close.setAttribute('data-action', '1');
        var closeX = mkEl('span', { color: TXT3, marginRight: '8px' }, '✕');
        close.appendChild(closeX);
        close.appendChild(document.createTextNode('Close'));
        close.onclick = function() { overlay.style.display = 'none'; };
        hdr.appendChild(close);

        return hdr;
    }

    /* ── Status bar (below header, shows backup progress) ─────────── */
    function buildStatusBar() {
        var bar = mkEl('div', {
            position: 'absolute', top: '73px', left: '0', right: '0', height: '38px',
            background: BG, padding: '6px 24px',
            fontSize: '16px', color: TXT3, zIndex: '2',
            borderBottom: '1px solid ' + CARD_BD, display: 'none'
        });
        bar.id = 'tm-status-bar';
        return bar;
    }


    /* ── Main overlay ─────────────────────────────────────────────── */
    function showUI() {
        if (overlay) { overlay.style.display = 'block'; loadData(); return; }

        overlay = document.createElement('div');
        overlay.id = 'tweaks-overlay';
        setS(overlay, {
            position: 'fixed', top: '0', left: '0', width: '100%', height: '100%',
            background: BG, color: TXT, zIndex: '99999',
            fontFamily: 'sans-serif', display: 'block', overflow: 'hidden'
        });

        overlay.appendChild(buildHeader());
        overlay.appendChild(buildStatusBar());

        var content = mkEl('div', {
            position: 'absolute', top: '73px', bottom: '0', left: '0', right: '0',
            overflowY: 'auto', overflowX: 'hidden', padding: '16px 24px'
        });
        content.id = 'tweaks-content';
        enableScroll(content);
        overlay.appendChild(content);
        document.body.appendChild(overlay);

        loadData();
    }

    /* ── Data loading ─────────────────────────────────────────────── */
    function loadData() {
        var c = document.getElementById('tweaks-content');
        if (!c) return;
        c.innerHTML = '';
        c.appendChild(mkEl('div', {
            color: TXT3, fontSize: '20px', padding: '60px 0', textAlign: 'center'
        }, 'Loading...'));

        api('GET', '/api/version', function(s, ver) {
            if (!ver) {
                c.innerHTML = '';
                showError(c, 'tweaksd not running', '/data_persist/tweaks/tweaksd &');
                return;
            }
            cachedVer = ver;
            updateVerBadge();

            api('GET', '/api/usb/scan', function(s2, usb) {
                cachedUsb = usb;
                updateUsbStatus();

                if (!usb || !usb.usb_mounted) {
                    renderNoUsb(c);
                    return;
                }

                doSync(function() {
                    api('GET', '/api/dump/status', function(s3, dump) {
                        if (!dump || !dump.exists) {
                            renderNoDump(c);
                            return;
                        }

                        api('GET', '/api/tweaks/list', function(s4, data) {
                            cachedTweaks = data;
                            renderTweaks(c);
                        });
                    });
                });
            });
        });
    }

    /* ── No USB — blocking screen ─────────────────────────────────── */
    function renderNoUsb(c) {
        c.innerHTML = '';
        var box = mkEl('div', { padding: '50px 24px', textAlign: 'center' });

        var iconWrap = mkEl('div', {
            display: 'inline-block', width: '80px', height: '80px',
            background: BTN_BG, borderRadius: '20px',
            textAlign: 'center', lineHeight: '80px',
            fontSize: '36px', color: YELLOW, marginBottom: '20px',
            border: '1px solid ' + CARD_BD
        }, '⚠');
        box.appendChild(iconWrap);

        box.appendChild(mkEl('div', {
            fontSize: '24px', color: TXT, fontWeight: 'bold', marginBottom: '10px'
        }, 'USB drive required'));

        box.appendChild(mkEl('div', {
            fontSize: '18px', color: TXT2, marginBottom: '8px', lineHeight: '1.5'
        }, 'Insert the Tweaks Manager USB drive to continue.'));

        box.appendChild(mkEl('div', {
            fontSize: '16px', color: TXT3, marginBottom: '30px', lineHeight: '1.5'
        }, 'All backups and logs are synced to USB on every session for safety.'));

        var retry = mkEl('div', {
            display: 'inline-block', padding: '14px 36px',
            background: '#0891b2', color: '#fff', borderRadius: '10px',
            cursor: 'pointer', fontSize: '18px', fontWeight: 'bold',
            border: '1px solid ' + CYAN, letterSpacing: '2px'
        }, 'RETRY');
        retry.setAttribute('data-action', '1');
        retry.onclick = function() {
            retry.textContent = 'Scanning...';
            retry.style.background = BTN_BG2;
            loadData();
        };
        box.appendChild(retry);

        c.appendChild(box);
    }

    /* ── Mandatory sync: backup + logs to USB ─────────────────────── */
    function doSync(onDone) {
        var bar = document.getElementById('tm-status-bar');
        var c = document.getElementById('tweaks-content');
        if (bar) {
            bar.style.display = 'block';
            bar.textContent = '↻  Syncing backup + logs to USB...';
            bar.style.color = CYAN;
        }
        if (c) c.style.top = '112px';

        api('POST', '/api/backups/export', function(s1, r1) {
            var bOk = r1 && r1.ok;
            api('POST', '/api/log/export', function(s2, r2) {
                var lOk = r2 && r2.ok;

                if (bar) {
                    if (bOk && lOk) {
                        bar.textContent = '✓  Backup + logs synced to USB';
                        bar.style.color = GREEN;
                    } else if (bOk) {
                        bar.textContent = '✓  Backup synced  |  ✗ log export failed';
                        bar.style.color = YELLOW;
                    } else {
                        bar.textContent = '✗  Sync failed — check USB';
                        bar.style.color = RED;
                    }
                }

                setTimeout(function() {
                    if (bar) bar.style.display = 'none';
                    if (c) c.style.top = '73px';
                    onDone();
                }, 2000);
            });
        });
    }

    /* ── Header updates ───────────────────────────────────────────── */
    function updateVerBadge() {
        var el = document.getElementById('tm-ver-badge');
        if (el && cachedVer) el.textContent = 'v' + (cachedVer.version || '?');
    }

    function updateUsbStatus() {
        var el = document.getElementById('tm-usb-status');
        if (!el) return;
        if (cachedUsb && cachedUsb.usb_mounted) {
            el.textContent = '●  USB';
            el.style.color = CYAN;
        } else {
            el.textContent = '○  No USB';
            el.style.color = TXT3;
        }
    }

    /* ── Error display ────────────────────────────────────────────── */
    function showError(c, msg, hint) {
        c.innerHTML = '';
        var box = mkEl('div', {
            padding: '50px 24px', textAlign: 'center'
        });
        box.appendChild(mkEl('div', {
            fontSize: '24px', color: RED, fontWeight: 'bold', marginBottom: '16px'
        }, msg));
        if (hint) {
            box.appendChild(mkEl('div', {
                fontSize: '16px', color: TXT3
            }, 'Start: ' + hint));
        }
        c.appendChild(box);
    }

    /* ── No-dump screen ───────────────────────────────────────────── */
    function renderNoDump(c) {
        c.innerHTML = '';
        var box = mkEl('div', { padding: '40px 24px', textAlign: 'center' });

        box.appendChild(mkEl('div', {
            fontSize: '22px', color: YELLOW, fontWeight: 'bold', marginBottom: '10px'
        }, 'System dump required'));
        box.appendChild(mkEl('div', {
            fontSize: '18px', color: TXT3, marginBottom: '24px'
        }, 'A backup of system files is needed before installing tweaks.'));

        var dbtn = mkEl('div', {
            display: 'inline-block', padding: '16px 40px',
            background: '#0891b2', color: '#fff', borderRadius: '10px',
            cursor: 'pointer', fontSize: '20px', fontWeight: 'bold',
            border: '1px solid ' + CYAN, letterSpacing: '2px'
        }, 'CREATE DUMP');
        dbtn.setAttribute('data-action', '1');

        var st = mkEl('div', { marginTop: '16px', color: TXT3, fontSize: '16px' });

        dbtn.onclick = function() {
            dbtn.textContent = 'Creating...';
            dbtn.style.background = BTN_BG2;
            api('POST', '/api/dump/create', function(s, res) {
                if (res && res.ok) {
                    dbtn.textContent = '✓ Done';
                    dbtn.style.background = GREEN;
                    setTimeout(function() { loadData(); }, 1000);
                } else {
                    dbtn.textContent = 'CREATE DUMP';
                    dbtn.style.background = '#0891b2';
                    st.textContent = 'Failed: ' + ((res && res.error) || 'insert USB and retry');
                    st.style.color = RED;
                }
            });
        };

        box.appendChild(dbtn);
        box.appendChild(st);
        c.appendChild(box);
    }

    /* ── Tweak cards ──────────────────────────────────────────────── */
    function renderTweaks(c) {
        c.innerHTML = '';
        if (!cachedTweaks || !cachedTweaks.tweaks) {
            c.appendChild(mkEl('div', {
                color: RED, fontSize: '20px', padding: '30px', textAlign: 'center'
            }, 'Failed to load tweaks'));
            return;
        }

        var tweaks = cachedTweaks.tweaks;
        if (tweaks.length === 0) {
            c.appendChild(mkEl('div', {
                color: TXT3, fontSize: '20px', padding: '60px 0', textAlign: 'center'
            }, 'No tweaks found. Insert USB with tweaks.'));
            return;
        }

        for (var i = 0; i < tweaks.length; i++) {
            c.appendChild(makeTweakCard(tweaks[i]));
        }
    }

    function makeTweakCard(t) {
        var card = mkEl('div', {
            position: 'relative',
            background: CARD_BG,
            border: '1px solid ' + CARD_BD,
            borderLeft: '4px solid ' + (t.installed ? GREEN : BTN_BG2),
            borderRadius: '10px',
            padding: '18px 24px',
            paddingRight: '200px',
            marginBottom: '12px'
        });

        var titleRow = mkEl('div', { marginBottom: '8px' });
        titleRow.appendChild(mkEl('span', {
            fontSize: '20px', fontWeight: 'bold', color: TXT
        }, t.name));

        var ver = t.installed ? t.installed_version : t.version;
        if (ver) {
            var vbadge = mkEl('span', {
                display: 'inline-block', marginLeft: '10px',
                padding: '2px 10px', borderRadius: '12px',
                fontSize: '14px', color: TXT3,
                background: BTN_BG, border: '1px solid ' + BTN_BG2,
                verticalAlign: 'middle'
            }, 'v' + ver);
            titleRow.appendChild(vbadge);
        }
        card.appendChild(titleRow);

        if (t.description) {
            card.appendChild(mkEl('div', {
                fontSize: '16px', color: TXT2, marginBottom: '10px',
                lineHeight: '1.4'
            }, t.description));
        }

        var badges = mkEl('div', { fontSize: '0' });

        if (t.installed) {
            badges.appendChild(makeBadge('●  INSTALLED', GREEN));
            if (t.update_available) {
                badges.appendChild(makeBadge('↑  UPDATE v' + t.version, BLUE));
            }
        } else if (t.setup) {
            badges.appendChild(makeBadge('●  READY', CYAN));
        } else if (t.has_source) {
            badges.appendChild(makeBadge('AVAILABLE ON USB', TXT3));
        } else {
            badges.appendChild(makeBadge('NOT ON USB', TXT3));
        }
        card.appendChild(badges);

        var btnArea = mkEl('div', {
            position: 'absolute', right: '20px', top: '50%',
            marginTop: '-24px'
        });

        if (t.installed) {
            if (t.update_available && t.has_source) {
                btnArea.appendChild(makeActionBtn('UPDATE', CYAN, t, 'install'));
                btnArea.appendChild(mkEl('span', { display: 'inline-block', width: '8px' }));
            }
            btnArea.appendChild(makeActionBtn('UNINSTALL', RED, t, 'uninstall'));
        } else if (t.setup) {
            btnArea.appendChild(makeActionBtn('INSTALL', GREEN, t, 'install'));
        } else if (t.has_source) {
            btnArea.appendChild(makeActionBtn('SETUP', CYAN, t, 'setup'));
        }

        card.appendChild(btnArea);
        return card;
    }

    function makeBadge(text, color) {
        return mkEl('span', {
            display: 'inline-block',
            padding: '4px 14px',
            marginRight: '8px',
            borderRadius: '6px',
            fontSize: '14px',
            fontWeight: 'bold',
            letterSpacing: '1px',
            color: color,
            background: hexToRgba(color, 0.12),
            border: '1px solid ' + hexToRgba(color, 0.25)
        }, text);
    }

    var actionBusy = false;

    function reloadList() {
        api('GET', '/api/tweaks/list', function(s, data) {
            if (data) {
                cachedTweaks = data;
                var c = document.getElementById('tm-content');
                if (c) renderTweaks(c);
            }
        });
    }

    function makeActionBtn(label, color, tweak, action) {
        var filled = (label === 'UPDATE' || label === 'SETUP');
        var b = mkEl('span', {
            display: 'inline-block', padding: '12px 28px',
            background: filled ? CYAN : 'transparent',
            color: filled ? '#fff' : color,
            borderRadius: '8px', cursor: 'pointer',
            fontSize: '16px', fontWeight: 'bold',
            letterSpacing: '2px',
            border: '1px solid ' + color
        }, label);
        b.setAttribute('data-action', '1');
        b.onclick = function() {
            if (actionBusy) return;
            actionBusy = true;

            if (action === 'setup') {
                showModal('Copying ' + tweak.name + ' to CMU...');
                api('POST', '/api/tweaks/setup/' + tweak.id, function(s, res) {
                    if (res && res.ok) {
                        actionBusy = false;
                        updateModal('✓', 'Ready to install', '', GREEN, 1500);
                        setTimeout(function() { reloadList(); }, 1600);
                    } else {
                        actionBusy = false;
                        var err = (res && res.error) || 'Setup failed';
                        updateModal('✗', 'Setup failed', err, RED, 3000);
                    }
                });
                return;
            }

            var isUpd = (action === 'install' && tweak.installed);

            if (isUpd) {
                showModal('Updating ' + tweak.name + '...');
                api('POST', '/api/tweaks/update/' + tweak.id, function(s, res) {
                    if (res && res.ok) {
                        if (res.reboot) {
                            showRebootModal('Updated');
                        } else {
                            actionBusy = false;
                            updateModal('✓', 'Updated', '', GREEN, 1500);
                        }
                    } else {
                        actionBusy = false;
                        var err = (res && res.error) || 'Update failed';
                        updateModal('✗', 'Update failed', err, RED, 3000);
                    }
                });
            } else {
                var verb = action === 'install' ? 'Installing' : 'Uninstalling';
                showModal(verb + ' ' + tweak.name + '...');
                api('POST', '/api/tweaks/' + action + '/' + tweak.id, function(s, res) {
                    if (res && res.ok) {
                        if (res.reboot) {
                            showRebootModal(action === 'install' ? 'Installed' : 'Uninstalled');
                        } else {
                            actionBusy = false;
                            updateModal('✓', 'Done', '', GREEN, 1500);
                        }
                    } else {
                        actionBusy = false;
                        var err = (res && res.error) || 'Operation failed';
                        updateModal('✗', 'Failed', err, RED, 3000);
                    }
                });
            }
        };
        return b;
    }

    /* ── Modal popup for operations ──────────────────────────────── */
    var modal = null;

    function showModal(title) {
        if (modal) modal.parentNode.removeChild(modal);
        modal = mkEl('div', {
            position: 'fixed', top: '0', left: '0', width: '100%', height: '100%',
            background: 'rgba(0,0,0,0.7)', zIndex: '100000',
            display: 'block'
        });

        var box = mkEl('div', {
            position: 'absolute', top: '50%', left: '50%',
            width: '420px', marginLeft: '-210px', marginTop: '-100px',
            background: CARD_BG, border: '1px solid ' + CARD_BD,
            borderRadius: '16px', padding: '36px 32px',
            textAlign: 'center'
        });

        var spinner = mkEl('div', {
            fontSize: '36px', color: CYAN, marginBottom: '18px'
        }, '↻');
        spinner.id = 'modal-icon';
        box.appendChild(spinner);

        var msg = mkEl('div', {
            fontSize: '22px', color: TXT, fontWeight: 'bold', marginBottom: '10px'
        }, title);
        msg.id = 'modal-title';
        box.appendChild(msg);

        var sub = mkEl('div', {
            fontSize: '16px', color: TXT3, lineHeight: '1.5'
        }, 'Do not turn off the engine');
        sub.id = 'modal-sub';
        box.appendChild(sub);

        modal.appendChild(box);
        document.body.appendChild(modal);
    }

    function updateModal(icon, title, sub, color, autoDismiss) {
        var ic = document.getElementById('modal-icon');
        var ti = document.getElementById('modal-title');
        var su = document.getElementById('modal-sub');
        if (ic) { ic.textContent = icon; ic.style.color = color || GREEN; }
        if (ti) ti.textContent = title;
        if (su) { su.textContent = sub || ''; su.style.color = color || TXT3; }
        if (autoDismiss && modal) {
            setTimeout(function() {
                dismissModal();
                loadData();
            }, autoDismiss);
        }
    }

    function dismissModal() {
        if (modal && modal.parentNode) modal.parentNode.removeChild(modal);
        modal = null;
    }

    function showRebootModal(verb) {
        updateModal('⏻', verb + ' — reboot required', 'Tap Reboot when ready', CYAN, 0);
        var box = document.getElementById('modal-sub');
        if (!box || !box.parentNode) return;
        var wrap = mkEl('div', { marginTop: '20px', textAlign: 'center' });
        var btnR = mkEl('div', {
            display: 'inline-block', padding: '12px 36px',
            background: CYAN, color: '#000', fontWeight: 'bold',
            fontSize: '18px', borderRadius: '8px', cursor: 'pointer',
            marginRight: '12px'
        }, 'REBOOT');
        btnR.onclick = function() {
            updateModal('⏻', 'Rebooting...', '', CYAN, 0);
            api('POST', '/api/system/reboot', function() {});
        };
        var btnS = mkEl('div', {
            display: 'inline-block', padding: '12px 24px',
            border: '1px solid ' + TXT3, color: TXT3,
            fontSize: '18px', borderRadius: '8px', cursor: 'pointer'
        }, 'LATER');
        btnS.onclick = function() {
            actionBusy = false;
            dismissModal();
            loadData();
        };
        wrap.appendChild(btnR);
        wrap.appendChild(btnS);
        box.parentNode.appendChild(wrap);
    }

    /* ── Helpers ───────────────────────────────────────────────────── */
    function hexToRgba(hex, alpha) {
        var r = parseInt(hex.substr(1, 2), 16);
        var g = parseInt(hex.substr(3, 2), 16);
        var b = parseInt(hex.substr(5, 2), 16);
        return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
    }

    /* ── Entry point ──────────────────────────────────────────────── */
    function tryInit() {
        if (!document.body) {
            var n = 0;
            var iv = setInterval(function() {
                if (document.body || ++n > 30) {
                    clearInterval(iv);
                    if (document.body) start();
                }
            }, 1000);
        } else {
            start();
        }
    }

    function start() {
        createButton();
        setInterval(checkVisibility, 1500);
        dbg('started, polling visibility');
    }

    if (window.opera && window.opera.addEventListener) {
        window.opera.addEventListener('AfterEvent.load', function() {
            dbg('load');
            tryInit();
        }, false);
    } else {
        tryInit();
    }
})();
