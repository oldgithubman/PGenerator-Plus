#!/usr/bin/env node
'use strict';

const assert=require('assert');
const fs=require('fs');
const source=fs.readFileSync('usr/share/PGenerator/webui.pm','utf8');

assert(source.includes("localStorage.getItem('pgen.ui.themeMode')"),'theme is restored in the head bootstrap');
assert(source.indexOf("localStorage.getItem('pgen.ui.themeMode')")<source.indexOf('<style>'),'saved theme is applied before CSS and paint');
assert(source.includes("const PG_THEME_STORAGE_KEY='pgen.ui.themeMode';"),'runtime controller uses the namespaced key');
assert(/return saved==='light'\|\|saved==='dark'\?saved:'dark'/.test(source),'invalid storage falls back to dark');
assert(source.includes("catch(e){ return 'dark'; }"),'inaccessible storage falls back to dark');
assert(source.includes('[data-theme="light"]{color-scheme:light'),'light mode sets native color-scheme');
assert(source.includes(':root,[data-theme="dark"]{color-scheme:dark'),'dark remains the CSS default');
assert(source.includes("new CustomEvent('pgen:themechange'"),'runtime changes emit a dedicated event');
assert(source.includes('pgRedrawChartsForTheme();'),'runtime changes redraw charts');
assert(!/function pgRedrawChartsForTheme\([\s\S]{0,700}meterRefreshActiveSeriesCharts/.test(source),'theme redraw does not rebuild measurement state');

const uiCard=(source.match(/id="uiSettingsCard"/g)||[]).length;
assert.strictEqual(uiCard,1,'UI Settings card has one ID');
assert(source.includes('data-desktop-workspace="ui-settings"'),'UI Settings is a tablet card and desktop workspace');
assert(source.indexOf('data-workspace-target="ui-settings"')<source.indexOf('data-workspace-target="system"'),'UI Settings navigation precedes System');
for(const mode of ['tablet','desktop']){
 const controls=(source.match(new RegExp('<button[^>]+data-layout-mode="'+mode+'"','g'))||[]).length;
 assert.strictEqual(controls,2,mode+' has exactly a header shortcut and settings tile');
}
for(const mode of ['dark','light']){
 assert.strictEqual((source.match(new RegExp('data-theme-mode="'+mode+'"','g'))||[]).length,1,mode+' has one appearance tile');
}
assert(source.includes("document.querySelectorAll('.layout-switch-btn[data-layout-mode]')"),'header and card layout controls share synchronization');
assert(source.includes("btn.disabled=unavailable"),'all Desktop controls respect width eligibility');
assert(source.includes("note.classList.toggle('is-visible',!pgWideEnoughForDesktop())"),'width restriction has a visible explanation');
assert(source.includes("btn.setAttribute('aria-pressed',btn.getAttribute('data-theme-mode')===pgThemeMode?'true':'false')"),'theme selected state is accessible');

console.log('webui theme mode regression OK');
