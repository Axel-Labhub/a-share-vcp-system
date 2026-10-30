(() => {
  'use strict';
  const BRIDGE = '/state.json';
  const INDEXES = [
    {symbol:'sh000001',name:'上证指数'}, {symbol:'sz399001',name:'深证成指'},
    {symbol:'sz399006',name:'创业板指'}, {symbol:'sh000688',name:'科创50'}
  ];
  const POLL_MS = 30000;
  const $ = id => document.getElementById(id);
  let data = null, quotes = {}, busy = false, bridgeOnline = false;
  let bridgeSuccess = null, quoteSuccess = null, quoteAttempt = null;
  let nextAt = Date.now() + POLL_MS, lastSignature = '';
  const storage = {
    get(key) { try { return localStorage.getItem(key); } catch (_) { return null; } },
    set(key,value) { try { localStorage.setItem(key,value); } catch (_) {} }
  };
  function text(id,value) { const node=$(id); if(node) node.textContent=value==null?'—':String(value); }
  function el(tag,cls,value) { const n=document.createElement(tag); if(cls)n.className=cls; if(value!=null)n.textContent=String(value); return n; }
  function num(v,d=2) { return v!==null && v!==undefined && v!=='' && Number.isFinite(Number(v)) ? Number(v).toFixed(d) : '—'; }
  function dateKey(date=new Date()) {
    const parts=new Intl.DateTimeFormat('en',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(date);
    return ['year','month','day'].map(k=>parts.find(p=>p.type===k).value).join('-');
  }
  function time(v,full=false) {
    if(!v)return '—'; const d=new Date(v); if(!Number.isFinite(d.getTime()))return '—';
    const p=new Intl.DateTimeFormat('zh-CN',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).formatToParts(d);
    const part=k=>p.find(x=>x.type===k)?.value||'';
    return (full?part('year')+'-':'')+part('month')+'-'+part('day')+' '+part('hour')+':'+part('minute')+':'+part('second');
  }
  function pct(v) { return v==null?'—':(Number(v)>0?'+':'')+num(v)+'%'; }
  function ageText(ms) {
    if(ms<0)return '时间异常';
    const minutes=Math.floor(ms/60000);
    if(minutes<1)return '不足1分钟';
    if(minutes<60)return minutes+'分钟';
    const hours=Math.floor(minutes/60),remaining=minutes%60;
    if(hours<48)return hours+'小时'+(remaining?remaining+'分钟':'');
    const days=Math.floor(hours/24),left=hours%24;
    return days+'天'+(left?left+'小时':'');
  }
  function updateScanAge() {
    const value=data?.scan?.scan_time, parsed=value?Date.parse(value):NaN;
    if(!Number.isFinite(parsed)) {text('scanAge','无可核验时间');text('scanAgeDetail','扫描时间待核验');return;}
    const age=Date.now()-parsed, sameDay=dateKey(new Date(parsed))===dateKey();
    if(age < -10000) {text('scanAge','时间异常');text('scanAgeDetail','扫描时间晚于当前时间，待核验');return;}
    text('scanAge',time(value)+' · '+ageText(Math.max(0,age))+'前');
    text('scanAgeDetail',sameDay?'当日最后扫描批次 · 非盘中实时':'跨日 / 仅供回看 · 以报告时间为准');
  }
  function symbols() { return [...new Set(INDEXES.map(x=>x.symbol).concat((data?.watchlist?.items||[]).map(x=>x.symbol)))]; }
  function phase() {
    const p=new Intl.DateTimeFormat('en',{timeZone:'Asia/Shanghai',weekday:'short',hour:'2-digit',minute:'2-digit',hour12:false}).formatToParts(new Date());
    const value=k=>p.find(x=>x.type===k)?.value;
    const minute=Number(value('hour'))*60+Number(value('minute'));
    if(['Sat','Sun'].includes(value('weekday')))return '非连续竞价时段';
    if((minute>=570&&minute<690)||(minute>=780&&minute<900))return '连续竞价时段（时段估算）';
    if(minute>=690&&minute<780)return '午间休市（时段估算）';
    return '非连续竞价时段';
  }
  async function fetchJson(url) {
    const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),10000);
    try { const response=await fetch(url,{cache:'no-store',signal:controller.signal}); if(!response.ok)throw Error('unavailable'); return await response.json(); }
    finally {clearTimeout(timeout);}
  }
  function validState(d) { return d&&d.schema_version===1&&d.scan&&Array.isArray(d.watchlist?.items); }
  function bridgeStatus() {
    const snapshotOnly=data?.mode==='deployment_snapshot';
    text('bridgeStatus',bridgeOnline?'数据桥在线':snapshotOnly?'静态部署快照':'数据桥离线 / 保留最近数据');
    text('footerBridge',bridgeOnline?'在线 · 只读同步':snapshotOnly?'公开快照 · 无在线状态同步':'离线或未连接 · 不伪造更新');
    $('bridgeDot').classList.toggle('good',bridgeOnline);
    text('snapshotSync',data?.generated_at?time(data.generated_at,true):'无可核验时间');
    text('lastSync',bridgeSuccess?time(bridgeSuccess):snapshotOnly?'未请求在线同步':'本页尚未成功同步');
    text('dataMode',bridgeOnline?'· 云端文件同步':data?.mode==='project_live'?'· 上次云端数据（连接失败）':'· 部署快照');
    text('bridgeDetail',bridgeOnline?'当前云端项目副本可访问；新扫描文件写入后，下次轮询即可读到。':snapshotOnly?'当前为静态公开快照；快照同步、扫描和行情各按来源时间分别标记，不会将旧扫描视为实时。':'同步不可用：保留最近数据并显示原始扫描时间；不会把部署快照当作新扫描。');
  }
  async function syncBridge() {
    if(data?.mode==='deployment_snapshot'){bridgeOnline=false;bridgeStatus();return;}
    try { const d=await fetchJson(BRIDGE+'?t='+Date.now()); if(!validState(d)||d.mode!=='project_live')throw Error('invalid'); applyData(d); bridgeOnline=true; bridgeSuccess=new Date().toISOString(); }
    catch (_) {bridgeOnline=false;}
    bridgeStatus();
  }
  function applyData(d) {
    data=d; const s=d.scan||{}, w=d.watchlist||{};
    text('poolCount',s.pool_count); text('passedCount',s.passed_count); text('selectedCount',s.selected_count);
    text('selectedRatio',(s.selected_count??'—')+' / 3'); text('featuredRatio',(s.selected_count??'—')+' / 3');
    text('scanTime',s.scan_time?time(s.scan_time,true).slice(0,16):'—'); text('scanDate','数据截止 '+(s.data_date||'—'));
    text('emptyScanTime',time(s.scan_time)); text('scanTimeFull',time(s.scan_time,true)); text('scanSource',s.source);
    text('reportName',s.report_name); text('watchCount',w.items.length); text('watchUpdated',w.updated||'未知日期');
    text('benchmarkDay',pct(s.benchmark_day_pct)); text('benchmark20',pct(s.benchmark_20d_pct));
    $('benchmarkDay').className=s.benchmark_day_pct<0?'down':s.benchmark_day_pct>0?'up':'';
    text('scoreReject',(s.rejections||[]).find(x=>x.name==='评分低于70')?.count??'—');
    text('brakeState',s.benchmark_day_pct==null?'无法核验':s.market_brake?'已触发':'未触发');
    $('brakeState').className=s.market_brake?'warning':'';
    text('scanStatus',s.status==='ok'?'已完成':s.status==='market_brake'?'市场刹车':'结果待核验');
    text('scanGroupCount',s.group_count==null?'—':s.group_count+' 组'); text('distributionTotal','总计 '+(s.pool_count??'—'));
    renderCandidates(s); renderBars('distributionBars',s.distribution||[],s.pool_count,false); renderBars('rejectionBars',s.rejections||[],s.pool_count,true);
    populateGroups(w.items); renderWatchlist(); renderPaper(d.daily_paper||{},d.intraday_paper||{});
  }
  function renderCandidates(s) {
    const box=$('candidates'); box.replaceChildren();
    const items=(s.candidates||[]).slice(0,3);
    if(!items.length) {
      box.className='empty-state'; const icon=el('div','empty-orbit','∅'), copy=el('div');
      copy.append(el('h3','',s.status==='ok'?'没有合格 VCP，宁可等待':'没有可核验的精选信号'));
      copy.append(el('p','',s.status==='ok'?'本轮严格扫描没有产生候选。观察名单不会被用于填补精选席位。':'数据缺失或市场刹车时不展示未核验信号，也不补位。'));
      const meta=el('div','empty-meta');meta.append(el('span','','最新扫描'),el('b','',time(s.scan_time)));box.append(icon,copy,meta);
      text('signalState',s.status==='ok'?'等待信号':'等待核验'); return;
    }
    box.className='candidate-grid'; text('signalState','规则候选 · 非指令');
    items.forEach(x=>{
      const card=el('article','candidate-card');card.append(el('h3','',x.name||x.symbol),el('p','muted',x.symbol+' · '+(x.label||'规则候选')));
      const score=el('div','candidate-score',num(x.score,0)+'/100'); card.append(score);
      const dl=el('dl','candidate-facts'); [['收盘',num(x.close)],['枢轴',num(x.pivot)],['量比',num(x.volume_ratio)+'×'],['技术止损参考',x.technical_stop||'—']].forEach(([k,v])=>{const row=el('div');row.append(el('dt','',k),el('dd','',v));dl.append(row);});
      card.append(dl,el('p','fine-print','评分只用于排序，不是收益概率或成交保证。'));box.append(card);
    });
  }
  function renderBars(id,rows,total,amber) {
    const root=$(id);root.replaceChildren();const scale=Number(total)||Math.max(...rows.map(x=>x.count||0),1);
    rows.forEach(x=>{const row=el('div','bar-row'+(amber?' rejection-bars':''));const track=el('span','bar-track'),fill=el('span','bar-fill');fill.style.width=Math.max(0,Math.min(100,Number(x.count)/scale*100))+'%';track.append(fill);const label=el('span','bar-label',x.name);label.title=x.name;row.append(label,track,el('span','bar-value',x.count));root.append(row);});
  }
  function parseQuote(raw,symbol) {
    const f=String(raw).split('~'), stamp=f[30];
    if(f.length<35||f[2]!==symbol.slice(2)||!/^\d{14}$/.test(stamp||''))throw Error('fields');
    const price=Number(f[3]),change=Number(f[31]),percentage=Number(f[32]);
    if(!(price>0)||![price,change,percentage].every(Number.isFinite))throw Error('price');
    const sourceISO=stamp.slice(0,4)+'-'+stamp.slice(4,6)+'-'+stamp.slice(6,8)+'T'+stamp.slice(8,10)+':'+stamp.slice(10,12)+':'+stamp.slice(12,14)+'+08:00';
    const sourceMs=Date.parse(sourceISO);if(!Number.isFinite(sourceMs)||dateKey(new Date(sourceMs))!==sourceISO.slice(0,10))throw Error('time');
    return {symbol,name:f[1],price,change,pct:percentage,sourceISO,sourceMs,fetchFailed:false};
  }
  function freshness(q,now=Date.now()) {
    if(!q?.sourceMs)return {kind:'failed',label:'获取失败 / 暂无快照',fresh:false};
    let kind='fresh',label='新鲜 ≤90秒';
    if(q.sourceMs-now>10000){kind='clock';label='供应方时间异常';}
    else if(dateKey(new Date(q.sourceMs))!==dateKey(new Date(now))){kind='cross-day';label='跨日 / 仅供回看';}
    else if(now-q.sourceMs>90000){kind='stale';label='过期 >90秒 / 仅供回看';}
    if(q.fetchFailed)return {kind:'failed',label:'本轮失败 · '+(kind==='fresh'?'保留上次值':label),fresh:false};
    return {kind,label,fresh:kind==='fresh'};
  }
  function jsonpQuote(list) {
    return new Promise(resolve=>{
      const script=document.createElement('script');let done=false, timeout;
      list.forEach(s=>{window['v_'+s]='';});
      const finish=failed=>{
        if(done)return;done=true;clearTimeout(timeout);script.remove();const result={};
        list.forEach(s=>{try {if(failed)throw Error('request');result[s]=parseQuote(window['v_'+s],s);}catch(_){result[s]=null;}try{delete window['v_'+s];}catch(_){window['v_'+s]=undefined;}});
        resolve(result);
      };
      script.charset='gbk'; script.referrerPolicy='no-referrer';
      script.onload=()=>finish(false);script.onerror=()=>finish(true);
      timeout=setTimeout(()=>finish(true),10000);
      script.src='https://qt.gtimg.cn/q='+list.join(',')+'&_t='+Date.now();document.head.append(script);
    });
  }
  async function refreshQuotes() {
    const list=symbols();quoteAttempt=new Date().toISOString();const result=await jsonpQuote(list);let success=0;
    list.forEach(s=>{if(result[s]){quotes[s]=result[s];success++;}else{quotes[s]={...(quotes[s]||{symbol:s}),fetchFailed:true};}});
    if(success)quoteSuccess=new Date().toISOString(); renderQuotes();
  }
  function changeNode(q) {
    if(q?.price==null)return el('span','quote-status','—');
    return el('span',q.change>=0?'up':'down',(q.change>=0?'+':'')+num(q.change)+' ('+pct(q.pct)+')');
  }
  function renderQuotes() {
    const root=$('marketGrid');root.replaceChildren();let freshIndex=0,staleIndex=0,failedIndex=0;
    INDEXES.forEach(item=>{
      const q=quotes[item.symbol],status=freshness(q),card=el('article','quote-card '+status.kind);
      const heading=el('h3','',item.name);card.append(heading,el('div','quote-price',num(q?.price)));
      const change=el('div','quote-change');change.append(changeNode(q));card.append(change);
      const tm=el('div','quote-time');tm.append(el('span','','行情源 '+time(q?.sourceISO)),el('span','quote-status',status.label));card.append(tm);root.append(card);
      if(status.fresh)freshIndex++;else if(status.kind==='failed'||status.kind==='clock')failedIndex++;else staleIndex++;
    });
    text('freshCount',freshIndex);text('staleCount',staleIndex);text('failedCount',failedIndex);
    const list=symbols(), statuses=list.map(s=>freshness(quotes[s]));
    const fresh=statuses.filter(s=>s.fresh).length, failed=statuses.filter(s=>['failed','clock'].includes(s.kind)).length;
    text('qualityScore',fresh+' / '+list.length);text('qualityScope','新鲜 '+fresh+' · 过期/跨日 '+(list.length-fresh-failed)+' · 失败/异常 '+failed+'（含观察名单）');
    $('gaugeFill').style.width=(list.length?fresh/list.length*100:0)+'%';
    const sourceTimes=list.map(s=>quotes[s]?.sourceISO).filter(Boolean).sort();
    text('quoteRange',sourceTimes.length?time(sourceTimes[0])+' — '+time(sourceTimes[sourceTimes.length-1]):'无可核验供应方时间');
    text('quoteFetched',quoteSuccess?time(quoteSuccess):'尚无成功报价');text('quoteAttempt',time(quoteAttempt));
    text('marketSummary',phase()+' · 最近快照价，不保证可成交');
    renderWatchlist();lastSignature=list.map(s=>freshness(quotes[s]).kind).join('|');
  }
  function populateGroups(items) {
    const select=$('groupFilter'),current=select.value;select.replaceChildren(el('option','','全部组别'));select.options[0].value='all';
    [...new Set(items.map(x=>x.group))].forEach(group=>{const option=el('option','',group);option.value=group;select.append(option);});
    select.value=[...select.options].some(x=>x.value===current)?current:'all';
  }
  function renderWatchlist() {
    const all=data?.watchlist?.items||[],root=$('watchGrid'),query=$('watchSearch').value.trim().toLowerCase(),group=$('groupFilter').value;
    const items=all.filter(x=>(!query||(x.name+x.symbol+x.group).toLowerCase().includes(query))&&(group==='all'||x.group===group));root.replaceChildren();
    text('watchShown',items.length+' / '+all.length+' 项');
    items.forEach(item=>{
      const q=quotes[item.symbol],status=freshness(q),card=el('article','watch-item '+status.kind),top=el('div','watch-top');
      top.append(el('div','watch-name',item.name),el('div','watch-symbol',item.symbol));card.append(top,el('div','watch-group',item.group));
      const quote=el('div','watch-quote'),change=el('div','watch-change');change.append(changeNode(q));quote.append(el('div','watch-price',num(q?.price)),change);card.append(quote);
      card.append(el('div','watch-time','行情源 '+time(q?.sourceISO)),el('div','quote-status watch-status',status.label));root.append(card);
    });
    if(!items.length)root.append(el('p','muted','没有匹配的观察标的。'));
  }
  function renderPositionList(rootId,items) {
    const root=$(rootId);root.replaceChildren();(items||[]).forEach(p=>{
      const row=el('div','position-row');row.append(el('strong','',p.name+' '+p.symbol),el('span','','模拟入场 '+(p.entry_date||'—')+' / '+num(p.entry_price)),el('span','','最近记录 '+num(p.last_price)+' · 非真实账户'));root.append(row);
    });
  }
  function renderPaper(d,i) {
    text('dailyPending',d.state_available?d.pending_count:'—');text('dailyOpen',d.state_available?d.open_count:'—');text('dailyClosed',d.state_available?d.closed_count:'—');
    text('dailyPaperTitle',!d.state_available?'日线纸面状态不可用':d.open_count?'模拟持仓 '+d.open_count+' 笔':'暂无模拟持仓');
    text('dailyPaperTime','最近处理 '+time(d.last_run_time,true)+' · 数据日 '+(d.last_processed_date||'—')+' · 台账文件 '+time(d.state_updated_at,true));
    renderPositionList('dailyPositions',d.open_positions);
    if(!i.state_available){text('intradayBadge','未核验');text('intradayTitle','无可核验状态，不能认定正在运行');text('intradayDetail','无候选且无在途模拟持仓时，不启动空监控。当前未发现可核验状态记录。');}
    else {text('intradayBadge','独立纸面记录');text('intradayTitle','模拟持仓 '+(i.open_count??'—')+' · 已完成 '+(i.closed_count??'—'));text('intradayDetail','最近轮询记录 '+time(i.last_poll,true)+'；文件更新 '+time(i.state_updated_at,true)+'。记录存在不等于实例持续运行。');}
    renderPositionList('intradayPositions',i.open_positions);
  }
  async function refreshAll() {
    if(busy)return;busy=true;nextAt=Date.now()+POLL_MS;$('refreshBtn').disabled=true;$('refreshBtn').setAttribute('aria-busy','true');
    try {await Promise.all([syncBridge(),refreshQuotes()]);}
    finally {busy=false;$('refreshBtn').disabled=false;$('refreshBtn').setAttribute('aria-busy','false');}
  }
  function tick() {
    text('clock','上海 '+time(new Date().toISOString()));
    updateScanAge();
    text('countdown',$('autoRefresh').checked?(busy?'刷新中':Math.max(0,Math.ceil((nextAt-Date.now())/1000))+'s'):'已暂停');
    const signature=symbols().map(s=>freshness(quotes[s]).kind).join('|');if(signature!==lastSignature)renderQuotes();
    if(!document.hidden&&$('autoRefresh').checked&&Date.now()>=nextAt&&!busy)refreshAll();
  }
  $('autoRefresh').checked=storage.get('vcp-auto')!=='off';
  $('autoRefresh').addEventListener('change',()=>{storage.set('vcp-auto',$('autoRefresh').checked?'on':'off');if($('autoRefresh').checked){nextAt=Date.now()+POLL_MS;refreshAll();}tick();});
  $('refreshBtn').addEventListener('click',refreshAll);$('watchSearch').addEventListener('input',renderWatchlist);$('groupFilter').addEventListener('change',renderWatchlist);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden&&$('autoRefresh').checked)refreshAll();});
  const links=[...document.querySelectorAll('.side-nav nav a, .bottom-nav a')];
  if('IntersectionObserver' in window){const observer=new IntersectionObserver(entries=>{entries.filter(e=>e.isIntersecting).forEach(e=>links.forEach(a=>a.classList.toggle('active',a.hash==='#'+e.target.id)));},{rootMargin:'-10% 0px -65% 0px'});['overview','market','scan','watchlist','paper','rules'].forEach(id=>observer.observe($(id)));}
  (async()=>{try{const d=await fetchJson('data.json');if(validState(d))applyData(d);}catch(_){text('bridgeStatus','部署快照无法读取');}bridgeStatus();renderQuotes();tick();await refreshAll();setInterval(tick,1000);})();
})();
