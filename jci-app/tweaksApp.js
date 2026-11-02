/*
 * Tweaks Manager — JCI Application (Opera userjs)
 *
 * Loaded by Opera via /jci/opera/opera_dir/userjs/
 * Registers the tweaks app with JCI framework when ready.
 *
 * Contexts:
 *   TweaksList   — main list of all tweaks (installed + USB)
 *   TweakDetail  — detail view for a single tweak
 */
(function() {
    'use strict';

    var TWEAKSD = 'http://127.0.0.1:8035';
    var registered = false;

    function dbg(msg) {
        try { window.opera.postError('[tweaks-app] ' + msg); } catch(e) {}
    }

    /* ── Utility ── */

    function api(method, path, cb) {
        var xhr = new XMLHttpRequest();
        xhr.open(method, TWEAKSD + path, true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                var data = null;
                try { data = JSON.parse(xhr.responseText); } catch(e) {}
                cb(xhr.status, data);
            }
        };
        xhr.timeout = 10000;
        xhr.onerror = function() { cb(0, null); };
        xhr.send();
    }

    /* ── State ── */

    var tweaksList = [];
    var selectedTweak = null;
    var dumpExists = false;

    /* ── Registration ── */

    function tryRegister() {
        if (registered) return true;
        if (typeof framework !== 'object' || !framework) return false;
        if (typeof framework.registerAppLoaded !== 'function') return false;

        try {
            framework.registerAppLoaded('tweaks', null, {

                appInit: function() {
                    this.uiaId = 'tweaks';
                },

                appReadyToDisplay: function() {
                    checkDumpAndLoadList();
                },

                _contextTable: {

                    'TweaksList': {
                        'template': 'List2Tmplt',
                        'sbNameId': 'Tweaks',
                        'controlProperties': {
                            'List2Ctrl': {
                                'dataList': null,
                                'titleConfiguration': 'listTitle',
                                'title': { 'text1Id': 'Tweaks Manager', 'titleStyle': 'titleStyle01' },
                                'selectCallback': onTweakSelected
                            },
                            'SbNameId': 'Tweaks'
                        },
                        'readyFunction': function() {
                            refreshList();
                        }
                    },

                    'TweakDetail': {
                        'template': 'Dialog3Tmplt',
                        'controlProperties': {
                            'Dialog3Ctrl': {
                                'defaultSelectCallback': onDetailAction,
                                'contentStyle': 'style02',
                                'fullScreen': false
                            }
                        },
                        'readyFunction': function() {
                            showTweakDetail();
                        }
                    }
                }
            });

            registered = true;
            dbg('app registered');
        } catch(e) {
            dbg('register failed: ' + e);
            return false;
        }

        return true;
    }

    /* ── List Logic ── */

    function checkDumpAndLoadList() {
        api('GET', '/api/dump/status', function(status, data) {
            if (data && data.exists) {
                dumpExists = true;
                loadTweaks();
            } else {
                dumpExists = false;
                showDumpRequired();
            }
        });
    }

    function loadTweaks() {
        api('GET', '/api/tweaks/list', function(status, data) {
            if (data && data.tweaks) {
                tweaksList = data.tweaks;
                refreshList();
            }
        });
    }

    function refreshList() {
        if (!tweaksList.length && dumpExists) {
            setListItems([{
                title: 'No tweaks found',
                text1Id: 'Insert USB with tweaks',
                disabled: true,
                itemStyle: 'style01',
                hasCaret: false,
                appData: { appName: 'tweaks', mmuiEvent: 'none' }
            }]);
            return;
        }

        var items = [];
        for (var i = 0; i < tweaksList.length; i++) {
            var t = tweaksList[i];
            var label = t.name;
            var sublabel = t.description;

            if (t.installed && t.update_available) {
                label = '[UPD] ' + label;
                sublabel = 'v' + t.installed_version + ' → v' + t.version;
            } else if (t.installed) {
                label = '[ON] ' + label;
                sublabel = 'v' + t.installed_version;
            } else {
                sublabel = 'v' + t.version + ' — ' + t.author;
            }

            items.push({
                title: label,
                text1Id: sublabel,
                disabled: false,
                itemStyle: 'style02',
                hasCaret: true,
                appData: {
                    appName: 'tweaks',
                    mmuiEvent: 'SelectTweakDetail',
                    tweakIndex: i
                }
            });
        }

        items.push({
            title: '─── Tools ───',
            text1Id: '',
            disabled: true,
            itemStyle: 'style01',
            hasCaret: false,
            appData: { appName: 'tweaks', mmuiEvent: 'none' }
        });
        items.push({
            title: 'Export backups to USB',
            text1Id: 'Copy per-tweak file backups to USB drive',
            disabled: false,
            itemStyle: 'style02',
            hasCaret: true,
            appData: { appName: 'tweaks', mmuiEvent: 'ExportBackups' }
        });
        items.push({
            title: 'Export log to USB',
            text1Id: 'Save install/uninstall history to USB drive',
            disabled: false,
            itemStyle: 'style02',
            hasCaret: true,
            appData: { appName: 'tweaks', mmuiEvent: 'ExportLog' }
        });

        setListItems(items);
    }

    function setListItems(items) {
        try {
            var app = framework.getAppInstance('tweaks');
            if (!app) return;
            var ctxt = app._contextTable['TweaksList'];
            if (!ctxt) return;
            ctxt.controlProperties.List2Ctrl.dataList = {
                itemCount: items.length,
                items: items,
                vuiSupport: false,
                selectDisabled: false
            };
            var ctrl = document.querySelector('.List2Ctrl');
            if (ctrl && ctrl._data) {
                ctrl._data.dataList = ctxt.controlProperties.List2Ctrl.dataList;
                if (typeof ctrl.updateItems === 'function') {
                    ctrl.updateItems(0, items.length);
                }
            }
        } catch(e) {}
    }

    function onTweakSelected(listCtrlObj, appData, params) {
        if (!appData || appData.mmuiEvent === 'none') return;

        if (appData.mmuiEvent === 'CreateDump') {
            createDump();
            return;
        }
        if (appData.mmuiEvent === 'ExportBackups') {
            exportToUsb('/api/backups/export', 'Exporting backups...', 'Backups exported to USB');
            return;
        }
        if (appData.mmuiEvent === 'ExportLog') {
            exportToUsb('/api/log/export', 'Exporting log...', 'Log exported to USB');
            return;
        }
        if (typeof appData.tweakIndex !== 'undefined') {
            selectedTweak = tweaksList[appData.tweakIndex];
            try { framework.sendEventToMmui('tweaks', 'SelectTweakDetail'); } catch(e) {}
        }
    }

    /* ── Dump Required Screen ── */

    function showDumpRequired() {
        setListItems([
            {
                title: '⚠ System dump required',
                text1Id: 'A backup must be created before installing tweaks',
                disabled: true, itemStyle: 'style01', hasCaret: false,
                appData: { appName: 'tweaks', mmuiEvent: 'none' }
            },
            {
                title: 'Create system dump now',
                text1Id: 'Saves config backup to USB drive',
                disabled: false, itemStyle: 'style02', hasCaret: true,
                appData: { appName: 'tweaks', mmuiEvent: 'CreateDump' }
            }
        ]);
    }

    function createDump() {
        setListItems([{
            title: 'Creating system dump...',
            text1Id: 'Please wait, do not remove USB',
            disabled: true, itemStyle: 'style01', hasCaret: false,
            appData: { appName: 'tweaks', mmuiEvent: 'none' }
        }]);

        api('POST', '/api/dump/create', function(status, data) {
            if (data && data.ok) {
                dumpExists = true;
                setListItems([{
                    title: 'Dump created successfully',
                    text1Id: 'Loading tweaks...',
                    disabled: true, itemStyle: 'style01', hasCaret: false,
                    appData: { appName: 'tweaks', mmuiEvent: 'none' }
                }]);
                setTimeout(function() { loadTweaks(); }, 1500);
            } else {
                var msg = (data && data.error) ? data.error : 'Unknown error';
                setListItems([
                    {
                        title: 'Dump failed: ' + msg,
                        text1Id: 'Make sure USB drive is inserted',
                        disabled: true, itemStyle: 'style01', hasCaret: false,
                        appData: { appName: 'tweaks', mmuiEvent: 'none' }
                    },
                    {
                        title: 'Retry',
                        text1Id: '',
                        disabled: false, itemStyle: 'style02', hasCaret: true,
                        appData: { appName: 'tweaks', mmuiEvent: 'CreateDump' }
                    }
                ]);
            }
        });
    }

    /* ── USB Export Helper ── */

    function exportToUsb(endpoint, progressMsg, successMsg) {
        setListItems([{
            title: progressMsg,
            text1Id: 'Please wait, do not remove USB',
            disabled: true, itemStyle: 'style01', hasCaret: false,
            appData: { appName: 'tweaks', mmuiEvent: 'none' }
        }]);

        api('POST', endpoint, function(status, data) {
            if (data && data.ok) {
                setListItems([{
                    title: successMsg,
                    text1Id: 'Returning to tweaks list...',
                    disabled: true, itemStyle: 'style01', hasCaret: false,
                    appData: { appName: 'tweaks', mmuiEvent: 'none' }
                }]);
                setTimeout(function() { loadTweaks(); }, 1500);
            } else {
                var msg = (data && data.error) ? data.error : 'Unknown error';
                setListItems([{
                    title: 'Export failed: ' + msg,
                    text1Id: 'Make sure USB drive is inserted',
                    disabled: true, itemStyle: 'style01', hasCaret: false,
                    appData: { appName: 'tweaks', mmuiEvent: 'none' }
                }]);
                setTimeout(function() { loadTweaks(); }, 2000);
            }
        });
    }

    /* ── Detail Logic ── */

    function showTweakDetail() {
        if (!selectedTweak) return;
        var t = selectedTweak;
        try {
            var dlg = document.querySelector('.Dialog3');
            if (!dlg) return;

            var status = t.installed ? 'Installed (v' + t.installed_version + ')' : 'Not installed';
            if (t.update_available) status += ' — Update available: v' + t.version;

            var html =
                '<div style="padding:10px;font-family:sans-serif">' +
                '<div style="font-size:22px;font-weight:bold;margin-bottom:8px">' +
                    escHtml(t.name) + '</div>' +
                '<div style="font-size:14px;color:#999;margin-bottom:12px">' +
                    'v' + escHtml(t.version) + ' by ' + escHtml(t.author) + '</div>' +
                '<div style="font-size:16px;margin-bottom:16px">' +
                    escHtml(t.description) + '</div>' +
                '<div style="font-size:14px;color:#ccc;margin-bottom:20px">' +
                    status + '</div>' +
                '<div id="tweaks-detail-actions"></div>' +
                '<div id="tweaks-detail-status" style="margin-top:12px;font-size:14px"></div>' +
                '</div>';

            dlg.innerHTML = html;

            var actionsDiv = document.getElementById('tweaks-detail-actions');
            if (!actionsDiv) return;

            if (t.installed && t.update_available && t.has_source) {
                actionsDiv.appendChild(makeBtn('Update', 'update'));
            }
            if (!t.installed && t.has_source) {
                actionsDiv.appendChild(makeBtn('Install', 'install'));
            }
            if (t.installed) {
                actionsDiv.appendChild(makeBtn('Uninstall', 'uninstall'));
            }
        } catch(e) {}
    }

    function makeBtn(label, action) {
        var btn = document.createElement('div');
        btn.style.cssText =
            'display:inline-block;padding:8px 24px;margin:4px 8px 4px 0;' +
            'background:#2a6496;color:#fff;border-radius:4px;cursor:pointer;' +
            'font-size:16px;text-align:center';
        btn.textContent = label;
        btn.setAttribute('data-action', action);
        btn.onclick = function() { onDetailAction(action); };
        return btn;
    }

    function onDetailAction(action) {
        if (!selectedTweak) return;
        var id = selectedTweak.id;
        var statusDiv = document.getElementById('tweaks-detail-status');

        if (action === 'install' || action === 'update') {
            if (statusDiv) statusDiv.textContent = 'Installing...';
            api('POST', '/api/tweaks/install/' + id, function(s, data) {
                if (data && data.ok) {
                    if (statusDiv) statusDiv.textContent =
                        'Installed!' + (data.reboot ? ' Reboot required.' : '');
                    loadTweaks();
                } else {
                    var err = (data && data.error) ? data.error : 'Failed';
                    if (statusDiv) statusDiv.textContent = 'Error: ' + err;
                }
            });
        } else if (action === 'uninstall') {
            if (statusDiv) statusDiv.textContent = 'Uninstalling...';
            api('POST', '/api/tweaks/uninstall/' + id, function(s, data) {
                if (data && data.ok) {
                    if (statusDiv) statusDiv.textContent =
                        'Removed.' + (data.reboot ? ' Reboot required.' : '');
                    loadTweaks();
                } else {
                    var err = (data && data.error) ? data.error : 'Failed';
                    if (statusDiv) statusDiv.textContent = 'Error: ' + err;
                }
            });
        }
    }

    function escHtml(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    /* ── Entry point: Opera AfterEvent.load ── */
    if (window.opera && window.opera.addEventListener) {
        window.opera.addEventListener('AfterEvent.load', function() {
            dbg('AfterEvent.load fired');
            if (!tryRegister()) {
                var attempts = 0;
                var iv = setInterval(function() {
                    attempts++;
                    if (tryRegister() || attempts > 60) {
                        clearInterval(iv);
                        if (!registered) dbg('gave up registering after ' + attempts + 's');
                    }
                }, 1000);
            }
        }, false);
        dbg('registered listener');
    }
})();
