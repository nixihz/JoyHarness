// THROWAWAY: all interactions stay in memory. No hardware, settings or task APIs.
const params = new URLSearchParams(location.search);
const state = {
  variant: ['A','B','C'].includes(params.get('variant')) ? params.get('variant') : 'A',
  device:'remote', scenario:'ready', theme:'dark', language:'zh', pressed:null,
  lastInput:null, dialog:null, mappingExpanded:false, simulatedFeedback:null,
};
const t = (zh,en) => state.language === 'zh' ? zh : en;
const escapeHTML = value => String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icons = {
  controller:'<path d="M6 7h12c3 0 5 10 2 11-2 1-4-3-5-3H9c-1 0-3 4-5 3C1 17 3 7 6 7Z"/><path d="M7 9v5m-2.5-2.5h5M16 10h.1M18 13h.1"/>',
  check:'<circle cx="12" cy="12" r="8"/><path d="m8 12 3 3 5-6"/>',
  warning:'<path d="M12 3 2 20h20L12 3Z"/><path d="M12 9v5m0 3h.01"/>',
  info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10h.01"/>',
  shield:'<path d="m12 3 8 3v6c0 4-5 7-8 9-3-2-8-5-8-9V6l8-3Z"/><path d="m8 12 3 3 5-6"/>',
  sliders:'<path d="M4 6h16M4 12h16M4 18h16M8 3v6m8 0v6m-6 0v6"/>',
  battery:'<rect x="2" y="7" width="17" height="10" rx="2"/><path d="M22 10v4M5 10v4m3-4v4m3-4v4m3-4v4"/>',
  input:'<path d="M2 13h4l3-8 5 14 3-6h5"/>',
  refresh:'<path d="M20 8a8 8 0 1 0 0 8M20 3v5h-5"/>',
  close:'<path d="m6 6 12 12M6 18 18 6"/>',
  pause:'<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
  gear:'<path d="m9 3-1 3-3 1 1 3-2 2 2 2-1 3 3 1 1 3 3-1 3 1 1-3 3-1-1-3 2-2-2-2 1-3-3-1-1-3-3 1Z"/><circle cx="12" cy="12" r="3"/>',
  mic:'<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8"/>',
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${icons[name]||icons.info}</svg>`;
// Remote: exact custom labels/actions observed in the local app on 2026-09-19.
// DualSense: ControllerMappingStore.baseDefaultMappings, not a connected-device claim.
const remote = [
 ['confirm','确认','Confirm','回车','Return',.50,.235],
 ['back','返回','Back','退格','Backspace',.28,.39],
 ['up','方向键 上','D-pad Up','↑ 上方向键','↑ Up Arrow',.50,.15],
 ['down','方向键 下','D-pad Down','↓ 下方向键','↓ Down Arrow',.50,.31],
 ['left','方向键 左','D-pad Left','← 左方向键','← Left Arrow',.20,.235],
 ['right','方向键 右','D-pad Right','→ 右方向键','→ Right Arrow',.80,.235],
 ['voice','语音','Voice','右侧 Command','Right Command',.76,.075],
 ['home','主页','Home','Esc','Escape',.28,.495],
 ['menu','菜单','Menu','鼠标右键','Right Click',.28,.60],
 ['custom','自定义键','Custom','飞书截图','Feishu Screenshot',.72,.60],
 ['volumeDown','音量 −','Volume −','上一个槽位','Previous Slot',.72,.495],
 ['volumeUp','音量 +','Volume +','下一个槽位','Next Slot',.72,.39],
];
const dualsense = [
 ['cross','✕','✕','鼠标左键','Left Click',.78,.37],['circle','○','○','鼠标右键','Right Click',.85,.27],
 ['square','□','□','退格','Backspace',.72,.27],['triangle','△','△','Esc','Escape',.78,.16],
 ['l1','L1','L1','上一个槽位','Previous Slot',.24,.065],['r1','R1','R1','下一个槽位','Next Slot',.76,.065],
 ['l2','L2','L2','功能层','Function Layer',.20,.025],['r2','R2','R2','聚焦 Codex','Focus Codex',.80,.025],
 ['create','Create','Create','截图工具','Screenshot Tool',.28,.12],['options','Options','Options','按住说话','Push to Talk',.72,.12],
 ['ps','PS','PS','切换运行模式','Toggle Operation Mode',.5,.54],['touch','触控板','Touchpad','鼠标左键','Left Click',.5,.18],
 ['l3','L3','L3','鼠标加速','Pointer Speed Boost',.34,.45],['r3','R3','R3','鼠标中键','Middle Click',.66,.45],
 ['up','方向键 上','D-pad Up','右侧 Command','Right Command',.21,.20],['down','方向键 下','D-pad Down','径向输入','Radial Input',.21,.34],
 ['left','方向键 左','D-pad Left','径向输入','Radial Input',.15,.27],['right','方向键 右','D-pad Right','径向输入','Radial Input',.27,.27],
 ['fCross','L2 + ✕','L2 + ✕','批准','Approve'],['fCircle','L2 + ○','L2 + ○','拒绝','Deny'],
 ['fSquare','L2 + □','L2 + □','回答 No','Answer No'],['fTriangle','L2 + △','L2 + △','回答 Yes','Answer Yes'],
 ['fL1','L2 + L1','L2 + L1','槽位 5','Slot 5'],['fR1','L2 + R1','L2 + R1','槽位 6','Slot 6'],
 ['fR2','L2 + R2','L2 + R2','回车','Return'],['fL3','L2 + L3','L2 + L3','复制','Copy'],['fR3','L2 + R3','L2 + R3','粘贴','Paste'],
 ['fUp','L2 + ↑','L2 + ↑','槽位 1','Slot 1'],['fLeft','L2 + ←','L2 + ←','槽位 2','Slot 2'],['fDown','L2 + ↓','L2 + ↓','槽位 3','Slot 3'],['fRight','L2 + →','L2 + →','槽位 4','Slot 4'],
 ['fStickUp','L2 + 右摇杆 ↑','L2 + Right Stick ↑','未分配','Unassigned'],['fStickLeft','L2 + 右摇杆 ←','L2 + Right Stick ←','浏览器后退','Browser Back'],
 ['fStickDown','L2 + 右摇杆 ↓','L2 + Right Stick ↓','未分配','Unassigned'],['fStickRight','L2 + 右摇杆 →','L2 + Right Stick →','浏览器前进','Browser Forward'],
];
const inputs = () => state.device === 'remote' ? remote : dualsense;
const physicalName = row => t(row[1],row[2]);
const actionName = row => t(row[3],row[4]);
const connected = () => ['ready','native','permission','unknown'].includes(state.scenario);
const nativeMode = () => state.scenario === 'native';
const deviceName = () => state.device === 'remote' ? t('小米蓝牙遥控器','Xiaomi Bluetooth Remote') : 'PS5 DualSense';
const variants = () => ({
 A:[t('控制器聚焦','Controller focus'),t('让手里的控制器，成为界面的中心。','Give the controller the centre of the window.'),t('连接与模式放在顶部；单个输入即时呈现；完整映射和连接详情按需打开。','Connection and mode first. One input at a time. Mappings and connection details open on demand.')],
 B:[t('映射对照','Mapping reference'),t('按下哪个键，会做什么。','See the button. Know the action.'),t('设备图与逐项映射共处一个工作区，适合熟悉按键与检查自定义配置。','Artwork and individual mappings share one workspace, for learning the controls and checking custom mappings.')],
 C:[t('紧凑工具窗','Compact utility'),t('确认可用，然后回到手头的工作。','Check it is ready. Get back to work.'),t('缩小设备图，保留连接、模式和输入反馈；按键参考在窗内展开。','A smaller device, with connection, mode and input feedback always visible. Expand the button reference when needed.')],
});
function statusLabel(){
 const labels={ready:['check','success',t('已连接','Connected')],native:['check','success',t('已连接','Connected')],permission:['check','success',t('已连接','Connected')],unknown:['check','success',t('已连接','Connected')],offline:['controller','muted',t('未连接','Disconnected')],connecting:['refresh','muted',t('正在连接','Connecting')],error:['warning','blocked',t('状态读取失败','Status unavailable')]};
 const [symbol,color,label]=labels[state.scenario];
 return `<span class="status ${color}">${icon(symbol)}${label}</span>`;
}
function modeLabel(){return nativeMode()?t('原生手柄模式 · 映射已暂停','Native mode · Mapping paused'):t('映射模式','Mapping mode')}
function button(action,label,primary=false,symbol=''){return `<button data-action="${action}" class="${primary?'primary':''}">${symbol?icon(symbol)+' ':''}${label}</button>`}
function titlebar(){return `<div class="titlebar"><div class="traffic" aria-hidden="true"><i></i><i></i><i></i></div><span>Joy Harness</span><button data-action="settings" class="icon-button" title="${t('设置','Settings')}" aria-label="${t('设置','Settings')}">${icon('gear')}</button></div>`}
function heading(primary=true){return `<header class="device-heading"><div><h2>${connected()?deviceName():t('控制器','Controller')}</h2><div class="status-line">${statusLabel()}${connected()?`<span class="mode">${modeLabel()}</span>`:''}</div></div>${connected()&&primary?button('mapping',t('配置按键','Configure Buttons'),true,'sliders'):''}</header>`}
function notice(){
 if(nativeMode())return `<div class="notice muted">${icon('pause')}<div><strong>${t('映射已暂停','Mapping is paused')}</strong><p>${t('前台应用：未知。切回映射模式后恢复按键操作。','Foreground application: unknown. Return to mapping mode to resume mapped actions.')}</p></div>${button('restore',t('恢复方式','How to Resume'))}</div>`;
 if(state.scenario==='permission')return `<div class="notice attention">${icon('warning')}<div><strong>${t('辅助功能未授权','Accessibility is not authorized')}</strong><p>${t('按键可被识别，鼠标和键盘模拟受限。请在系统设置中授权。','Input can be detected, but pointer and keyboard simulation are restricted. Grant access in System Settings.')}</p></div><button class="link" data-action="permission">${t('打开系统设置','Open System Settings')}</button></div>`;
 return '';
}
function artwork(small=false){
 const markers = small?'':inputs().filter(row=>row[5]!==undefined).map(row=>`<button class="hit" data-input="${row[0]}" style="left:${row[5]*100}%;top:${row[6]*100}%" aria-label="${escapeHTML(physicalName(row))}" title="${escapeHTML(physicalName(row)+' → '+actionName(row))}"></button>`).join('');
 return `<div class="artwork ${state.device} ${small?'small':''}"><img src="/assets/${state.device}.png" alt="" draggable="false">${markers}</div>`;
}
function battery(){return state.scenario!=='unknown'&&state.device==='remote'?`<span class="battery">${icon('battery')}100%</span>`:''}
function stage(small=false){return `<div class="stage">${artwork(small)}${small?'':`<div class="stage-battery">${battery()}</div><div class="stage-note">${icon('input')}${t('按下控制器按键<br>查看输入反馈','Press a controller button<br>to see input feedback')}</div>`}</div>`}
function readout(){
 const row=inputs().find(row=>row[0]===state.lastInput);
 const action=nativeMode()?t('映射已暂停','Mapping paused'):state.scenario==='permission'?t('未执行 · 权限受限','Not executed · Access restricted'):row?actionName(row):t('按键与动作将在这里显示','The button and action appear here');
 return `<div class="input-feedback ${state.pressed?'active':''}" role="status" aria-live="polite"><div class="live-symbol">${icon('input')}</div><div class="readout"><div><div class="meta">${t('物理输入','Physical input')}</div><div class="value">${row?`<kbd>${escapeHTML(physicalName(row))}</kbd>`:t('等待输入','Waiting for input')}</div></div>${row?'<span class="arrow" aria-hidden="true">→</span>':''}<div><div class="meta">${t('映射动作','Mapped action')}</div><div class="value">${escapeHTML(action)}</div></div></div>${row?`<span class="muted">${state.pressed?t('按下','Pressed'):t('已释放','Released')}</span>`:''}</div>`;
}
function footer(){
 const unknown=state.scenario==='unknown'||!connected();
 const permission=unknown?t('权限未知','Permissions unknown'):state.scenario==='permission'?t('部分权限未授权','Some permissions missing'):t('输入权限已授权','Input access authorized');
 return `<footer class="window-footer"><span class="footer-access">${icon('shield')}${permission}</span><div class="footer-actions"><button class="link" data-action="details">${t('连接详情','Connection Details')}</button>${connected()&&state.variant==='A'?`<button class="link" data-action="reference">${t('查看按键','Button Reference')}</button>`:''}</div></footer>`;
}
function empty(){
 const copy={offline:[t('连接你的控制器','Connect your controller'),t('通过蓝牙配对，或使用 USB 连接。连接后即可查看按键反馈。','Pair over Bluetooth or connect with USB. Input feedback appears once a controller is connected.')],connecting:[t('正在连接控制器','Connecting to the controller'),t('请保持控制器开启，等待连接完成。','Keep the controller powered on while the connection completes.')],error:[t('暂时无法读取控制器状态','Controller status is unavailable'),t('当前输入状态无法确认。重新读取后再检查连接。','The current input state could not be confirmed. Read the status again to check the connection.')]};
 const [title,description]=copy[state.scenario];
 return `<section class="empty">${icon(state.scenario==='error'?'warning':'controller')}<h3>${title}</h3><p>${description}</p>${state.scenario==='connecting'?button('disconnect',t('取消连接','Cancel Connection')):button('scan',state.scenario==='error'?t('重新读取状态','Read Status Again'):t('重新扫描控制器','Rescan Controllers'),true)}</section>`;
}
function table(all=false){
 const rows=all?inputs():inputs().slice(0,8);
 return `<table class="mapping-table"><thead><tr><th>${t('物理按键','Physical button')}</th><th>${t('映射动作','Mapped action')}${nativeMode()?` · ${t('已暂停','Paused')}`:''}</th></tr></thead><tbody>${rows.map(row=>`<tr><td><button class="mapping-key" data-input="${row[0]}" title="${t('预览输入','Preview input')}"><kbd>${escapeHTML(physicalName(row))}</kbd></button></td><td>${escapeHTML(actionName(row))}</td></tr>`).join('')}</tbody></table>`;
}
function VariantA(){return `${heading()}${notice()}${connected()?`${stage()}<div id="feedback">${readout()}</div>`:empty()}${footer()}`}
function VariantB(){return `${heading()}${notice()}${connected()?`<div class="comparison">${stage()}<section class="mapping-panel"><h3>${t('按键参考','Button reference')}</h3><p>${t('逐项查看当前按键的映射','See what each button is mapped to')}</p>${table()}<button class="link" data-action="reference">${t(`查看全部 ${inputs().length} 个输入`,`View all ${inputs().length} inputs`)} →</button></section></div><div id="feedback">${readout()}</div>`:empty()}${footer()}`}
function VariantC(){return `${connected()?`<div class="compact-top">${stage(true)}<div class="compact-summary">${heading(false)}${button('mapping',t('配置按键','Configure Buttons'),true,'sliders')}</div></div>${notice()}<div id="feedback" class="compact-input">${readout()}</div><details class="inline-disclosure" id="mapping-disclosure" ${state.mappingExpanded?'open':''}><summary>${t('按键参考','Button reference')}</summary>${table(true)}</details>`:`${heading()}${empty()}`}${footer()}`}
function render(){
 const [name,title,description]=variants()[state.variant];
 document.documentElement.dataset.theme=state.theme;
 document.documentElement.lang=state.language==='zh'?'zh-CN':'en';
 document.documentElement.style.setProperty('--window-width',({A:'744px',B:'824px',C:'600px'})[state.variant]);
 document.querySelector('#variant-kicker').textContent=t('方案 ','Variant ')+state.variant;
 document.querySelector('#variant-title').textContent=title;
 document.querySelector('#variant-description').textContent=description;
 document.querySelector('#variant-label').textContent=state.variant+' — '+name;
 document.querySelector('#window').innerHTML=titlebar()+`<div class="window-content">${({A:VariantA,B:VariantB,C:VariantC})[state.variant]()}</div>`;
 document.querySelector('#scenario').value=state.scenario;
 const disclosure=document.querySelector('#mapping-disclosure');
 if(disclosure)disclosure.addEventListener('toggle',()=>{state.mappingExpanded=disclosure.open;surfaceState()});
 surfaceState();
}
function surfaceState(){
 const selected=inputs().find(row=>row[0]===state.lastInput);
 const snapshot={...state,lastPhysicalInput:selected?physicalName(selected):null,configuredAction:selected?actionName(selected):null,controllerConnected:connected(),operationMode:nativeMode()?'native':'mapping',battery:state.device==='remote'&&connected()&&state.scenario!=='unknown'?100:null,mappingActionDispatched:false,dataSource:state.device==='remote'?'2026-09-19 local app mapping snapshot':'ControllerMappingStore.baseDefaultMappings',scenarioSource:'explicit prototype simulation'};
 document.querySelector('#state-output').textContent=JSON.stringify(snapshot,null,2);
 console.info('Dashboard prototype state',snapshot);
}
function setVariant(offset){
 const keys=['A','B','C'];state.variant=keys[(keys.indexOf(state.variant)+offset+3)%3];state.pressed=null;
 const url=new URL(location.href);url.searchParams.set('variant',state.variant);history.replaceState(null,'',url);render();
}
function updateFeedback(){
 const target=document.querySelector('#feedback');if(target)target.innerHTML=readout();
 document.querySelectorAll('[data-input]').forEach(button=>button.classList.toggle('pressed',button.dataset.input===state.pressed));
 surfaceState();
}
function pressInput(id){if(!connected())return;state.pressed=id;state.lastInput=id;updateFeedback()}
function releaseInput(){if(state.pressed){state.pressed=null;updateFeedback()}}
function detailRows(rows){return `<dl>${rows.map(([key,value])=>`<div><dt>${key}</dt><dd>${value}</dd></div>`).join('')}</dl>`}
function connectionDetails(){
 const unknown=t('未知','Unknown');
 return `<section class="detail-group"><h3>${icon('controller')}${t('控制器','Controller')}</h3>${detailRows([[t('设备','Device'),connected()?deviceName():unknown],[t('连接','Connection'),statusLabel()],[t('电量','Battery'),state.device==='remote'&&connected()&&state.scenario!=='unknown'?'100%':unknown],[t('震动能力','Haptic capability'),unknown],[t('逻辑控制器','Logical controller'),connected()?deviceName():unknown]])}</section><section class="detail-group"><h3>${icon('shield')}${t('权限与输入模式','Access and input mode')}</h3>${detailRows([[t('辅助功能','Accessibility'),!connected()||state.scenario==='unknown'?unknown:state.scenario==='permission'?t('未授权','Unauthorized'):t('已授权','Authorized')],[t('输入监控','Input monitoring'),!connected()||state.scenario==='unknown'?unknown:t('已授权','Authorized')],[t('输入模式','Input mode'),connected()?modeLabel():unknown],[t('前台应用','Foreground application'),unknown]])}</section><section class="detail-group"><h3>${icon('mic')}${t('扩展能力','Additional capabilities')}</h3>${detailRows([[t('适配器','Adapter'),unknown],[t('语音输入','Voice input'),unknown]])}<p class="dialog-note">${t('尚未读取的能力显示为未知。震动能力确认可用后才提供测试。','Capabilities that have not been read stay unknown. Haptic testing becomes available after support is confirmed.')}</p></section>`;
}
function openDialog(kind){
 state.dialog=kind;const dialog=document.querySelector('#dialog');
 const title=({details:t('连接详情','Connection Details'),mapping:t('按键映射','Button Mapping'),reference:t('按键参考','Button Reference'),permission:t('开启辅助功能权限','Enable Accessibility Access'),restore:t('恢复映射模式','Resume Mapping Mode'),settings:t('设置','Settings')})[kind];
 let content='';
 if(kind==='details')content=connectionDetails();
 if(kind==='reference')content=`<p class="dialog-note">${nativeMode()?t('映射已暂停。以下是已配置的动作，不代表正在执行。','Mapping is paused. These are configured actions; none are being executed.'):t('点击按键预览物理输入；映射动作不会被执行。','Click a key to preview input. Mapped actions are not executed.')}</p>${table(true)}`;
 if(kind==='mapping'||kind==='settings')content=`<p class="dialog-note">${t('设置入口预览 · 映射为只读快照','Settings entry preview · Mappings are a read-only snapshot')}</p><div class="settings-preview"><aside class="settings-sidebar"><span>${t('通用','General')}</span><span class="selected">${t('按键映射','Button Mapping')}</span><span>${t('槽位快捷键','Slot Shortcuts')}</span><span>${t('原生模式','Native Mode')}</span></aside><div><h3>${deviceName()}</h3><p class="dialog-note">${t('正式应用在原生设置窗口中使用 Picker 配置。此处仅预览入口与信息结构。','The native app uses Pickers in its Settings window. This preview shows the entry point and information structure.')}</p>${table(true)}</div></div>`;
 if(kind==='permission')content=`<p>${t('系统设置 → 隐私与安全性 → 辅助功能，允许 Joy Harness 控制电脑。','System Settings → Privacy & Security → Accessibility. Allow Joy Harness to control your computer.')}</p><p class="dialog-note">${t('原型仅展示指引，不修改系统权限。','This prototype only shows the instructions; it does not change system permissions.')}</p>`;
 if(kind==='restore')content=`<p>${state.device==='dualsense'?t('按 PS 键手动切回映射模式，或离开设置中指定的原生模式应用。','Press PS to return to mapping mode, or leave the application configured for native mode.'):t('离开设置中指定的原生模式应用后恢复映射。当前菜单键已自定义为鼠标右键，可在按键映射中配置“切换运行模式”。','Leave the application configured for native mode to resume mapping. Your Menu button is mapped to Right Click; configure Toggle Operation Mode in Button Mapping if needed.')}</p>`;
 dialog.innerHTML=`<header class="dialog-heading"><h2>${title}</h2><button class="icon-button" data-action="close" aria-label="${t('关闭','Close')}">${icon('close')}</button></header>${content}`;
 if(!dialog.open)dialog.showModal();surfaceState();
}
document.querySelector('#previous').addEventListener('click',()=>setVariant(-1));
document.querySelector('#next').addEventListener('click',()=>setVariant(1));
for(const key of ['device','scenario','theme','language'])document.querySelector('#'+key).addEventListener('change',event=>{state[key]=event.target.value;state.pressed=null;state.lastInput=null;state.simulatedFeedback=null;render()});
document.addEventListener('keydown',event=>{
 if(event.target.closest('input,textarea,select,[contenteditable="true"]')||document.querySelector('#dialog').open)return;
 if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();setVariant(event.key==='ArrowRight'?1:-1)}
});
document.addEventListener('pointerdown',event=>{const button=event.target.closest('[data-input]');if(button)pressInput(button.dataset.input)});
document.addEventListener('pointerup',releaseInput);document.addEventListener('pointercancel',releaseInput);window.addEventListener('blur',releaseInput);
document.addEventListener('keydown',event=>{const button=event.target.closest('[data-input]');if(button&&(event.key===' '||event.key==='Enter')){event.preventDefault();pressInput(button.dataset.input)}});
document.addEventListener('keyup',event=>{if(event.key===' '||event.key==='Enter')releaseInput()});
document.addEventListener('click',event=>{
 const button=event.target.closest('[data-action]');if(!button)return;
 const action=button.dataset.action;
 if(action==='close'){document.querySelector('#dialog').close();return}
 if(action==='scan'){state.scenario='connecting';state.simulatedFeedback='scan requested';render();return}
 if(action==='disconnect'){state.scenario='offline';state.pressed=null;state.lastInput=null;render();return}
 openDialog(action);
});
document.querySelector('#dialog').addEventListener('close',()=>{state.dialog=null;releaseInput();surfaceState()});
window.addEventListener('popstate',()=>{const value=new URLSearchParams(location.search).get('variant');state.variant=['A','B','C'].includes(value)?value:'A';render()});
render();
