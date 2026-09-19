// THROWAWAY: all interactions stay in memory. No hardware, settings or task APIs.
const params = new URLSearchParams(location.search);
const state = {
  variant: ['A','B','C'].includes(params.get('variant')) ? params.get('variant') : 'B',
  device:'remote', scenario:'ready', theme:'dark', language:'zh', pressed:null,
  lastInput:null, dialog:null, mappingExpanded:false, simulatedFeedback:null,
  connectionExpanded:true, orientation:'vertical', layer:'primary', hapticPreview:null,
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
  chip:'<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 2v3m6-3v3M9 19v3m6-3v3M2 9h3m-3 6h3m14-6h3m-3 6h3"/>',
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
const deviceProfiles = {
 remote:{name:['小米蓝牙遥控器','Xiaomi Bluetooth Remote'],haptics:false,touchpad:false,trigger:'none'},
 dualsense:{name:['PS5 DualSense','PS5 DualSense'],haptics:true,touchpad:true,trigger:'adaptive'},
 dualshock:{name:['PlayStation DualShock','PlayStation DualShock'],haptics:true,touchpad:true,trigger:'standard'},
 xbox:{name:['Xbox Wireless Controller','Xbox Wireless Controller'],haptics:true,touchpad:false,trigger:'impulse'},
 joyconLeft:{name:['Nintendo Joy-Con (L)','Nintendo Joy-Con (L)'],haptics:true,touchpad:false,trigger:'none'},
 joyconRight:{name:['Nintendo Joy-Con (R)','Nintendo Joy-Con (R)'],haptics:true,touchpad:false,trigger:'none'},
 joyconPair:{name:['Nintendo Joy-Con L + R','Nintendo Joy-Con L + R'],haptics:true,touchpad:false,trigger:'standard'},
 generic:{name:['通用控制器','Generic Controller'],haptics:null,touchpad:null,trigger:'unknown'},
};
const isJoyCon = () => state.device.startsWith('joycon');
const isSingleJoyCon = () => ['joyconLeft','joyconRight'].includes(state.device);
const profile = () => deviceProfiles[state.device];
const xboxPositions={cross:[.75,.40],circle:[.82,.30],square:[.68,.30],triangle:[.75,.20],up:[.37,.45],left:[.33,.51],down:[.37,.57],right:[.41,.51],l3:[.24,.29],r3:[.63,.50],options:[.58,.30],create:[.42,.30],ps:[.5,.38],l1:[.27,.07],r1:[.73,.07],l2:[.24,.035],r2:[.76,.035]};
function inputs(){
 if(state.device==='remote')return remote;
 if(['dualsense','dualshock'].includes(state.device))return dualsense;
 const solo=isSingleJoyCon();
 const permitted=['cross','circle','square','triangle','l1','r1','options','create','l3','fCross','fCircle','fSquare','fTriangle','fL1','fR1','fL3'];
 const left=state.device==='joyconLeft';
 const modifier=isJoyCon()?(state.device==='joyconRight'?'ZR':'ZL'):'LT';
 let names={cross:'A',circle:'B',square:'X',triangle:'Y',l1:'LB',r1:'RB',l2:'LT',r2:'RT',create:'Options / View',options:'Menu',ps:'Home',l3:'L3',r3:'R3'};
 if(isJoyCon()){
  const faces=solo?(left?['←','↓','↑','→']:['A','X','B','Y']):['B','A','Y','X'];
  names={...names,cross:faces[0],circle:faces[1],square:faces[2],triangle:faces[3],l1:solo?(state.orientation==='horizontal'?'SL':left?'L':'ZR'):'L',r1:solo?(state.orientation==='horizontal'?'SR':left?'ZL':'R'):'R',l2:modifier,r2:'ZR',create:solo?(left?'Capture':'Home'):'−',options:left?'−':'+',l3:solo?t('摇杆按下','Stick Click'):'L3'};
 }
 const functionBase={fCross:'cross',fCircle:'circle',fSquare:'square',fTriangle:'triangle',fL1:'l1',fR1:'r1',fR2:'r2',fL3:'l3',fR3:'r3'};
 return dualsense.filter(row=>row[0]!=='touch'&&(!solo||permitted.includes(row[0]))).map(row=>{
  let result=[...row];const id=row[0];
  if(names[id])result[1]=result[2]=names[id];
  else if(functionBase[id])result[1]=result[2]=modifier+' + '+names[functionBase[id]];
  else {result[1]=result[1].replace('L2',modifier);result[2]=result[2].replace('L2',modifier);}
  const position=state.device==='xbox'?xboxPositions[id]:null;
  result[5]=position?.[0];result[6]=position?.[1];return result;
 });
}
function capability(name){return !connected()||state.scenario==='unknown'?null:profile()[name]}
function capabilityText(value){return value===null?t('未知','Unknown'):value?t('可用','Available'):t('不可用','Unavailable')}

const physicalName = row => t(row[1],row[2]);
const actionName = row => t(row[3],row[4]);
const connected = () => ['ready','native','permission','unknown'].includes(state.scenario);
const nativeMode = () => state.scenario === 'native';
const deviceName = () => t(...profile().name);
const variants = () => ({
 A:[t('控制器聚焦','Controller focus'),t('让手里的控制器，成为界面的中心。','Give the controller the centre of the window.'),t('连接与模式放在顶部；单个输入即时呈现；完整映射和连接详情按需打开。','Connection and mode first. One input at a time. Mappings and connection details open on demand.')],
 B:[t('映射对照','Mapping reference'),t('按下哪个键，会做什么。','See the button. Know the action.'),t('设备与映射并排，完整链路信息在下方展开；随输入设备调整能力与按键。','Device and mappings side by side, with full connection details below. Controls and capabilities adapt to the input device.')],
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
 if(['generic','dualshock'].includes(state.device))return `<div class="symbol-artwork" role="img" aria-label="${deviceName()}">${icon('controller')}<span>${t('控制器示意','Controller symbol')}</span></div>`;
 const markers = small||isJoyCon()?'':inputs().filter(row=>row[5]!==undefined).map(row=>`<button class="hit" data-input="${row[0]}" style="left:${row[5]*100}%;top:${row[6]*100}%" aria-label="${escapeHTML(physicalName(row))}" title="${escapeHTML(physicalName(row)+' → '+actionName(row))}"></button>`).join('');
 const images=state.device==='joyconPair'?'<img src="/assets/joyconLeft.png" alt=""><img src="/assets/joyconRight.png" alt="">':`<img src="/assets/${state.device}.png" alt="" draggable="false">`;
 return `<div class="artwork ${state.device} ${isSingleJoyCon()?state.orientation:''} ${small?'small':''}">${images}${markers}</div>`;
}
function battery(){return state.scenario!=='unknown'&&state.device==='remote'?`<span class="battery">${icon('battery')}100%</span>`:''}
function stage(small=false){return `<div class="stage">${artwork(small)}${small?'':`<div class="stage-battery">${battery()}</div><div class="stage-note">${icon('input')}${t('点击按键参考<br>查看输入反馈','Click a key in the reference<br>to preview input')}</div>`}</div>`}
function orientationControl(){return isSingleJoyCon()?`<fieldset class="orientation"><legend>${t('握持方向','Grip orientation')}</legend>${['vertical','horizontal'].map(value=>`<label><input type="radio" name="orientation" value="${value}" ${state.orientation===value?'checked':''}>${value==='vertical'?t('竖握','Vertical'):t('横握','Horizontal')}</label>`).join('')}</fieldset>`:''}
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
 const rows=all?inputs():inputs().filter(row=>state.layer==='function'?row[0].startsWith('f'):!row[0].startsWith('f'));
 return `<table class="mapping-table"><thead><tr><th>${t('物理按键','Physical button')}</th><th>${t('映射动作','Mapped action')}${nativeMode()?` · ${t('已暂停','Paused')}`:''}</th></tr></thead><tbody>${rows.map(row=>`<tr><td><button class="mapping-key" data-input="${row[0]}" title="${t('预览输入','Preview input')}"><kbd>${escapeHTML(physicalName(row))}</kbd></button></td><td>${escapeHTML(actionName(row))}</td></tr>`).join('')}</tbody></table>`;
}
function VariantA(){return `${heading()}${notice()}${connected()?`${stage()}<div id="feedback">${readout()}</div>`:empty()}${footer()}`}
function VariantB(){return `${heading()}${notice()}${orientationControl()}${connected()?`<div class="comparison">${stage()}<section class="mapping-panel"><div class="mapping-panel-title"><h3>${t('按键参考','Button reference')}</h3>${state.device==='remote'?'':`<label class="layer-selector">${t('层','Layer')} <select id="layer"><option value="primary" ${state.layer==='primary'?'selected':''}>${t('基础按键','Primary buttons')}</option><option value="function" ${state.layer==='function'?'selected':''}>${t('功能层','Function layer')}</option></select></label>`}</div><p>${t('物理输入与映射动作逐项对应','Physical inputs and mapped actions, one by one')}</p><div class="mapping-scroll">${table()}</div></section></div><div id="feedback">${readout()}</div>`:empty()}<details class="connection-panel" id="connection-disclosure" ${state.connectionExpanded?'open':''}><summary><span>${t('链路状态','Connection status')}</span>${connectionHealth()}</summary>${connectionDetails()}</details><footer class="window-footer"><button class="link" data-action="settings">${icon('gear')} ${t('设置','Settings')}</button><span class="version">Joy Harness v0.5.1</span></footer>`}
function VariantC(){return `${connected()?`<div class="compact-top">${stage(true)}<div class="compact-summary">${heading(false)}${button('mapping',t('配置按键','Configure Buttons'),true,'sliders')}</div></div>${notice()}<div id="feedback" class="compact-input">${readout()}</div><details class="inline-disclosure" id="mapping-disclosure" ${state.mappingExpanded?'open':''}><summary>${t('按键参考','Button reference')}</summary>${table(true)}</details>`:`${heading()}${empty()}`}${footer()}`}
function render(){
 const [name,title,description]=variants()[state.variant];
 document.documentElement.dataset.theme=state.theme;
 document.documentElement.lang=state.language==='zh'?'zh-CN':'en';
 document.documentElement.style.setProperty('--window-width',({A:'744px',B:'880px',C:'600px'})[state.variant]);
 document.querySelector('#variant-kicker').textContent=t('方案 ','Variant ')+state.variant;
 document.querySelector('#variant-title').textContent=title;
 document.querySelector('#variant-description').textContent=description;
 document.querySelector('#variant-label').textContent=state.variant+' — '+name;
 document.querySelector('#window').innerHTML=titlebar()+`<div class="window-content">${({A:VariantA,B:VariantB,C:VariantC})[state.variant]()}</div>`;
 document.querySelector('#scenario').value=state.scenario;
 const connectionDisclosure=document.querySelector('#connection-disclosure');
 if(connectionDisclosure)connectionDisclosure.addEventListener('toggle',()=>{state.connectionExpanded=connectionDisclosure.open;surfaceState()});
 const disclosure=document.querySelector('#mapping-disclosure');
 if(disclosure)disclosure.addEventListener('toggle',()=>{state.mappingExpanded=disclosure.open;surfaceState()});
 surfaceState();
}
function surfaceState(){
 const selected=inputs().find(row=>row[0]===state.lastInput);
 const snapshot={...state,lastPhysicalInput:selected?physicalName(selected):null,configuredAction:selected?actionName(selected):null,controllerConnected:connected(),operationMode:nativeMode()?'native':'mapping',battery:state.device==='remote'&&connected()&&state.scenario!=='unknown'?100:null,mappingActionDispatched:false,dataSource:state.device==='remote'?'2026-09-19 local app mapping snapshot':'ControllerMappingStore defaults + explicit capability fixtures',scenarioSource:'explicit prototype simulation',capabilities:{haptics:capability('haptics'),touchpad:capability('touchpad'),trigger:profile().trigger},visibleInputs:inputs().map(row=>({input:physicalName(row),action:actionName(row)})),hapticDispatched:false};
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
function connectionHealth(){
 if(!connected())return statusLabel();
 if(state.scenario==='permission')return `<span class="status attention">${icon('warning')}${t('需要授权','Access needed')}</span>`;
 if(state.scenario==='unknown'||state.device==='generic')return `<span class="status muted">${icon('info')}${t('部分能力未知','Some capabilities unknown')}</span>`;
 return `<span class="status success">${icon('check')}${t('连接可用','Connection ready')}</span>`;
}
function connectionDetails(){
 const unknown=t('未知','Unknown');
 const readable=connected()&&state.scenario!=='unknown';
 const adapterKnown=state.scenario!=='unknown'&&state.scenario!=='error';
 const trigger=({none:t('不适用','Not applicable'),adaptive:t('自适应强反馈','Strong adaptive feedback'),impulse:t('Impulse Trigger 细微反馈','Subtle Impulse Trigger feedback'),standard:t('标准输入','Standard input'),unknown})[profile().trigger];
 const deviceRows=[[t('设备','Device'),connected()?deviceName():unknown],[t('类型','Type'),deviceName()],[t('震动','Haptics'),capabilityText(capability('haptics'))],[t('触控板','Touchpad'),capability('touchpad')===true?t('可映射','Mappable'):capabilityText(capability('touchpad'))]];
 if(profile().trigger!=='none')deviceRows.push([state.device==='xbox'?'RT':isJoyCon()?'ZR':t('RT / R2 扳机','RT / R2 trigger'),readable?trigger:unknown]);
 deviceRows.push([t('电量','Battery'),state.device==='remote'&&readable?'100%':unknown]);
 if(isJoyCon()){
  deviceRows.push([t('逻辑控制器','Logical controller'),state.device==='joyconPair'?t('双支组合','Paired'):t('单支','Single')]);
  if(isSingleJoyCon())deviceRows.push([t('握持方向','Grip orientation'),state.orientation==='horizontal'?t('横握','Horizontal'):t('竖握','Vertical')]);
  for(const side of state.device==='joyconPair'?['L','R']:[state.device==='joyconLeft'?'L':'R'])deviceRows.push(['Joy-Con '+side,readable?t('已连接 · 电量未知','Connected · Battery unknown'):unknown]);
  deviceRows.push([t('体感输入','Motion input'),readable?t('可用','Available'):unknown]);
 }
 const group=(title,symbol,rows,extra='')=>`<section class="detail-group"><h3>${icon(symbol)}${title}</h3>${detailRows(rows)}${extra}</section>`;
 const voice=!readable?unknown:state.device==='remote'?t('遥控器麦克风已连接（Joy Harness）','Remote microphone connected (Joy Harness)'):state.device==='generic'?unknown:state.device==='dualsense'?t('手柄未提供；当前使用系统默认输入','Controller input unavailable; using system default input'):t('当前使用系统默认输入','Using system default input');
 const access=!readable?unknown:state.scenario==='permission'?t('未授权','Unauthorized'):t('已授权','Authorized');
 const haptics=capability('haptics');
 const feedbacks=[['busy','input',t('执行反馈','Running feedback')],['waiting','pause',t('等待反馈','Waiting feedback')],['done','check',t('完成反馈','Completion feedback')],['error','warning',t('错误反馈','Error feedback')]];
 const hapticReason=haptics===true?t('选择一种反馈进行测试。','Choose a feedback pattern to test.'):haptics===false?t('此设备不支持震动，其他输入功能可正常使用。','This device does not support haptics. Other input functions remain available.'):t('震动能力尚未确认，确认可用后才能测试。','Haptic capability is unknown. Testing is available once support is confirmed.');
 return `<div class="connection-groups">${group(t('控制器','Controller'),'controller',deviceRows)}<div class="connection-right">${group(t('适配器','Adapter'),'chip',[[t('连接状态','Connection'),adapterKnown?t('已连接','Connected'):unknown],[t('模式','Mode'),adapterKnown?t('适配器连接','Adapter connection'):unknown]])}${group(t('运行模式','Runtime'),'shield',[[t('手柄模式','Gamepad mode'),connected()?modeLabel():unknown],[t('辅助功能','Accessibility'),access],[t('输入监控','Input monitoring'),readable?t('已授权','Authorized'):unknown],[t('语音输入','Voice input'),voice],[t('录音','Recording'),t('由 Codex Desktop 管理','Managed by Codex Desktop')]],state.device==='dualsense'?`<button class="link" data-action="sound">${t('打开声音输入设置','Open Sound Input Settings')}</button>`:'')}</div></div><section class="haptic-section"><h3>${icon('input')}${t('震动测试','Haptic test')}</h3><p class="dialog-note">${hapticReason}</p><div class="haptic-buttons">${feedbacks.map(([id,symbol,label])=>`<button data-haptic="${id}" aria-pressed="${state.hapticPreview===id}" ${haptics===true?'':'disabled'} aria-label="${t('测试','Test ')+label}">${icon(symbol)} ${label}</button>`).join('')}</div><p class="haptic-result" role="status">${state.hapticPreview?escapeHTML(t('已预览：','Previewed: ')+(feedbacks.find(row=>row[0]===state.hapticPreview)?.[2]??'')+t(' · 原型不触发真实震动',' · No real vibration in this prototype')):''}</p></section>`;
}
function openDialog(kind){
 state.dialog=kind;const dialog=document.querySelector('#dialog');
 const title=({details:t('连接详情','Connection Details'),mapping:t('按键映射','Button Mapping'),reference:t('按键参考','Button Reference'),permission:t('开启辅助功能权限','Enable Accessibility Access'),restore:t('恢复映射模式','Resume Mapping Mode'),settings:t('设置','Settings'),sound:t('声音输入设置','Sound Input Settings')})[kind];
 let content='';
 if(kind==='details')content=connectionDetails();
 if(kind==='reference')content=`<p class="dialog-note">${nativeMode()?t('映射已暂停。以下是已配置的动作，不代表正在执行。','Mapping is paused. These are configured actions; none are being executed.'):t('点击按键预览物理输入；映射动作不会被执行。','Click a key to preview input. Mapped actions are not executed.')}</p>${table(true)}`;
 if(kind==='mapping'||kind==='settings')content=`<p class="dialog-note">${t('设置入口预览 · 映射为只读快照','Settings entry preview · Mappings are a read-only snapshot')}</p><div class="settings-preview"><aside class="settings-sidebar"><span>${t('通用','General')}</span><span class="selected">${t('按键映射','Button Mapping')}</span><span>${t('槽位快捷键','Slot Shortcuts')}</span><span>${t('原生模式','Native Mode')}</span></aside><div><h3>${deviceName()}</h3><p class="dialog-note">${t('正式应用在原生设置窗口中使用 Picker 配置。此处仅预览入口与信息结构。','The native app uses Pickers in its Settings window. This preview shows the entry point and information structure.')}</p>${table(true)}</div></div>`;
 if(kind==='sound')content=`<p>${t('系统设置 → 声音 → 输入，选择可用的麦克风。','System Settings → Sound → Input. Select an available microphone.')}</p><p class="dialog-note">${t('原型仅展示入口，不修改音频设备。','The prototype previews this entry point; no audio devices are changed.')}</p>`;
 if(kind==='permission')content=`<p>${t('系统设置 → 隐私与安全性 → 辅助功能，允许 Joy Harness 控制电脑。','System Settings → Privacy & Security → Accessibility. Allow Joy Harness to control your computer.')}</p><p class="dialog-note">${t('原型仅展示指引，不修改系统权限。','This prototype only shows the instructions; it does not change system permissions.')}</p>`;
 if(kind==='restore'){
  const instruction=state.device==='remote'?t('离开设置中指定的原生模式应用后恢复映射。当前菜单键已自定义为鼠标右键，可在按键映射中配置“切换运行模式”。','Leave the application configured for native mode to resume mapping. Menu is currently mapped to Right Click; configure Toggle Operation Mode in Button Mapping if needed.'):isSingleJoyCon()?t('离开设置中指定的原生模式应用，或在按键映射中将一个按键设为“切换运行模式”。','Leave the application configured for native mode, or assign Toggle Operation Mode to a button.'):t('按 PS / Home 键切回映射模式，或离开设置中指定的原生模式应用。','Press PS / Home to return to mapping mode, or leave the application configured for native mode.');
  content=`<p>${instruction}</p>`;
 }

 dialog.innerHTML=`<header class="dialog-heading"><h2>${title}</h2><button class="icon-button" data-action="close" aria-label="${t('关闭','Close')}">${icon('close')}</button></header>${content}`;
 if(!dialog.open)dialog.showModal();surfaceState();
}
document.querySelector('#previous').addEventListener('click',()=>setVariant(-1));
document.querySelector('#next').addEventListener('click',()=>setVariant(1));
for(const key of ['device','scenario','theme','language'])document.querySelector('#'+key).addEventListener('change',event=>{state[key]=event.target.value;state.pressed=null;state.lastInput=null;state.simulatedFeedback=null;state.hapticPreview=null;if(key==='device')state.layer='primary';render()});
document.addEventListener('change',event=>{
 if(event.target.name==='orientation'){state.orientation=event.target.value;state.pressed=null;state.lastInput=null;render()}
 if(event.target.id==='layer'){state.layer=event.target.value;render()}
});
document.addEventListener('keydown',event=>{
 if(event.target.closest('input,textarea,select,[contenteditable="true"]')||document.querySelector('#dialog').open)return;
 if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();setVariant(event.key==='ArrowRight'?1:-1)}
});
document.addEventListener('pointerdown',event=>{const button=event.target.closest('[data-input]');if(button)pressInput(button.dataset.input)});
document.addEventListener('pointerup',releaseInput);document.addEventListener('pointercancel',releaseInput);window.addEventListener('blur',releaseInput);
document.addEventListener('keydown',event=>{const button=event.target.closest('[data-input]');if(button&&(event.key===' '||event.key==='Enter')){event.preventDefault();pressInput(button.dataset.input)}});
document.addEventListener('keyup',event=>{if(event.key===' '||event.key==='Enter')releaseInput()});
document.addEventListener('click',event=>{
 const haptic=event.target.closest('[data-haptic]');
 if(haptic&&capability('haptics')===true){state.hapticPreview=haptic.dataset.haptic;state.simulatedFeedback='haptic preview: '+state.hapticPreview;if(state.dialog==='details')openDialog('details');else render();return}
 const button=event.target.closest('[data-action]');if(!button)return;
 const action=button.dataset.action;
 if(action==='close'){document.querySelector('#dialog').close();return}
 if(action==='scan'){state.scenario='connecting';state.simulatedFeedback='scan requested';render();return}
 if(action==='disconnect'){state.scenario='offline';state.pressed=null;state.lastInput=null;render();return}
 openDialog(action);
});
document.querySelector('#dialog').addEventListener('close',()=>{state.dialog=null;releaseInput();surfaceState()});
window.addEventListener('popstate',()=>{const value=new URLSearchParams(location.search).get('variant');state.variant=['A','B','C'].includes(value)?value:'B';render()});
render();
