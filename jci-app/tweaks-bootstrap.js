/*
 * Tweaks Manager — JCI Bootstrap (Opera userjs)
 *
 * Loaded by Opera via /jci/opera/opera_dir/userjs/
 * Uses AfterEvent.load + _masterApplicationDataList (MZD-AIO pattern).
 *
 * Proxies through VDT app to avoid custom MMUI registration.
 */
(function() {
    'use strict';

    var PROXY_APP = 'vdt';
    var PROXY_CONTEXT = 'DriveChartDetails';
    var PROXY_EVENT = 'SelectDriveRecord';
    var TWEAKS_EVENT = 'SelectTweaks';
    var TWEAKS_ID = 'tweaks';
    var TWEAKS_LABEL = 'Tweaks';
    var bootstrapped = false;

    function dbg(msg) {
        try { window.opera.postError('[tweaks-boot] ' + msg); } catch(e) {}
    }

    function tryBootstrap() {
        if (bootstrapped) return true;
        if (typeof framework !== 'object' || !framework) return false;

        var systemApp;
        try { systemApp = framework.getAppInstance('system'); } catch(e) { return false; }
        if (!systemApp) return false;

        /* _masterApplicationDataList is the real source for Applications menu */
        if (!systemApp._masterApplicationDataList ||
            !systemApp._masterApplicationDataList.items) {
            dbg('no _masterApplicationDataList yet');
            return false;
        }

        var items = systemApp._masterApplicationDataList.items;

        /* avoid duplicate */
        for (var i = 0; i < items.length; i++) {
            if (items[i].appData &&
                items[i].appData.mmuiEvent === TWEAKS_EVENT) {
                dbg('already in menu');
                bootstrapped = true;
                return true;
            }
        }

        /* 1. Add to master app list */
        items.push({
            appData: {
                appName: TWEAKS_ID,
                isVisible: true,
                mmuiEvent: TWEAKS_EVENT
            },
            text1Id: TWEAKS_ID,
            disabled: false,
            itemStyle: 'style01',
            hasCaret: false
        });
        systemApp._masterApplicationDataList.itemCount = items.length;
        dbg('added to _masterApplicationDataList (' + items.length + ' items)');

        /* 2. Register display label in localization */
        try {
            if (framework.localize && framework.localize._appDicts &&
                framework.localize._appDicts['system']) {
                framework.localize._appDicts['system'][TWEAKS_ID] = TWEAKS_LABEL;
                dbg('localize registered');
            }
        } catch(e) { dbg('localize err: ' + e); }

        /* 3. Register context category */
        try {
            if (framework.common && framework.common._contextCategory &&
                framework.common._contextCategory._contextCategoryTable) {
                framework.common._contextCategory._contextCategoryTable[TWEAKS_ID + '.*'] = 'Applications';
                dbg('contextCategory registered');
            }
        } catch(e) { dbg('contextCategory err: ' + e); }

        /* 4. Register in _applicationsCtxtWiseAppNames if available */
        try {
            if (systemApp._applicationsCtxtWiseAppNames &&
                systemApp._applicationsCtxtWiseAppNames['Applications']) {
                var appNames = systemApp._applicationsCtxtWiseAppNames['Applications'];
                if (appNames.indexOf(TWEAKS_ID) === -1) {
                    appNames.push(TWEAKS_ID);
                    dbg('ctxtWiseAppNames registered');
                }
            }
        } catch(e) {}

        /* Hook menu selection, routing, events */
        hookMenuSelect(systemApp);
        hookRouteMmuiMsg();
        hookSendEvent();

        try {
            framework.transitionsObj._genObj._TEMPLATE_CATEGORIES_TABLE.SurfaceTmplt =
                'Detail with UMP';
        } catch(e) {}

        bootstrapped = true;
        dbg('bootstrap complete');
        return true;
    }

    function hookMenuSelect(systemApp) {
        var appCtxt = systemApp._contextTable && systemApp._contextTable['Applications'];
        if (!appCtxt || !appCtxt.controlProperties || !appCtxt.controlProperties.List2Ctrl) {
            dbg('hookMenuSelect: no Applications context, trying _menuItemSelectCallback directly');
        }

        /* Hook the list select callback */
        try {
            var lc = appCtxt.controlProperties.List2Ctrl;
            var origCb = lc.selectCallback;
            if (!origCb || systemApp._tweaksOrigSelectCb) return;
            systemApp._tweaksOrigSelectCb = origCb;

            lc.selectCallback = function(listCtrlObj, appData, params) {
                if (appData && appData.mmuiEvent === TWEAKS_EVENT) {
                    window._tweaksActive = true;
                    var proxyData = JSON.parse(JSON.stringify(appData));
                    proxyData.appName = PROXY_APP;
                    proxyData.mmuiEvent = PROXY_EVENT;
                    systemApp._menuItemSelectCallback(listCtrlObj, proxyData, params);
                    return;
                }
                origCb.call(systemApp, listCtrlObj, appData, params);
            };
            dbg('selectCallback hooked');
        } catch(e) { dbg('hookMenuSelect err: ' + e); }
    }

    function hookRouteMmuiMsg() {
        if (framework._tweaksOrigRoute) return;
        framework._tweaksOrigRoute = framework.routeMmuiMsg;
        framework.routeMmuiMsg = function(jsObject) {
            try {
                if (window._tweaksActive) {
                    if (jsObject.msgType === 'ctxtChg' && jsObject.uiaId === PROXY_APP) {
                        jsObject.uiaId = TWEAKS_ID;
                        jsObject.ctxtId = 'TweaksList';
                    }
                    if (jsObject.msgType === 'focusStack' && jsObject.appIdList) {
                        for (var i = 0; i < jsObject.appIdList.length; i++) {
                            if (jsObject.appIdList[i].id === PROXY_APP)
                                jsObject.appIdList[i].id = TWEAKS_ID;
                        }
                    }
                    if ((jsObject.msgType === 'msg' || jsObject.msgType === 'alert') &&
                        jsObject.uiaId === PROXY_APP)
                        jsObject.uiaId = TWEAKS_ID;
                }
            } catch(e) {}
            framework._tweaksOrigRoute(jsObject);
        };
    }

    function hookSendEvent() {
        if (framework._tweaksOrigSend) return;
        framework._tweaksOrigSend = framework.sendEventToMmui;
        framework.sendEventToMmui = function(uiaId, eventId, params, fromVui) {
            var cUia, cCtx;
            try { cUia = this.getCurrentApp(); cCtx = this.getCurrCtxtId(); }
            catch(e) { cUia = uiaId; cCtx = ''; }
            if (window._tweaksActive && cUia === TWEAKS_ID) {
                cUia = PROXY_APP;
                cCtx = PROXY_CONTEXT;
            }
            if (eventId === 'SelectBack' && uiaId === TWEAKS_ID)
                window._tweaksActive = false;
            framework._tweaksOrigSend(uiaId, eventId, params, fromVui, cUia, cCtx);
        };
    }

    /* ── Entry point: Opera AfterEvent.load (MZD-AIO pattern) ── */
    if (window.opera && window.opera.addEventListener) {
        window.opera.addEventListener('AfterEvent.load', function() {
            dbg('AfterEvent.load fired, framework: ' + (typeof framework));
            if (!tryBootstrap()) {
                var attempts = 0;
                var iv = setInterval(function() {
                    attempts++;
                    if (tryBootstrap() || attempts > 120) {
                        clearInterval(iv);
                        if (!bootstrapped) dbg('gave up after ' + attempts + 's');
                    }
                }, 1000);
            }
        }, false);
        dbg('registered');
    }
})();
