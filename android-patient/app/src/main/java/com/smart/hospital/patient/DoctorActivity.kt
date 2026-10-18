package com.smart.hospital.patient

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.Context
import android.content.res.Configuration
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.widget.*
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import com.smart.hospital.patient.data.*
import com.smart.hospital.patient.model.*
import com.smart.hospital.patient.ui.HarmonyUi
import com.smart.hospital.patient.ui.ThemeController
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/** Mirrors the Harmony doctor workflow; the server owns authorization and clinical state. */
class DoctorActivity : Activity() {
    private lateinit var session: SessionStore
    private lateinit var repo: DoctorRepository
    private lateinit var root: LinearLayout
    private lateinit var message: TextView
    private val worker=Executors.newSingleThreadExecutor()
    private var generation=0
    private var busy=false
    private var current: DoctorVisit?=null
    private var record: DoctorRecord?=null
    private var intake: IntakeSummary?=null
    private var intakeLoaded=false
    private var intakeError:String?=null
    private var history=emptyList<DoctorRecord>()
    private var historyLoaded=false
    private var historyError:String?=null
    private var dirty=false
    private var lockNeedsConfirmation=false
    private data class PendingSave(val appointmentId:Long,val version:Long,val values:Map<String,String>)
    private var pendingSave:PendingSave?=null
    private var reviewRecord:DoctorRecord?=null
    private var workspaceRestore:Bundle?=null
    private var workspaceIdentity:String?=null
    private val draft=linkedMapOf<String,String>()
    private val inputViews=linkedMapOf<String,EditText>()
    private var backCallback: OnBackInvokedCallback?=null
    private val palette get()=HarmonyUi.palette(this)
    private var displayedPalette:HarmonyUi.Palette?=null
    private fun dp(n:Int)=(n*resources.displayMetrics.density).toInt()
    override fun attachBaseContext(newBase:Context) {
        super.attachBaseContext(ThemeController.attachContext(newBase))
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        displayedPalette=palette
        session=SessionStore(this); repo=DoctorRepository(ApiClient(session),session)
        root=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL;setBackgroundColor(palette.bg) }
        setContentView(root)
        if(Build.VERSION.SDK_INT>=30) {
            window.setDecorFitsSystemWindows(false)
            root.setOnApplyWindowInsetsListener { v,i ->
                val safe=i.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
                v.setPadding(safe.left,safe.top,safe.right,safe.bottom);WindowInsets.CONSUMED
            }
        }
        if(Build.VERSION.SDK_INT>=33) backCallback=OnBackInvokedCallback { leaveEditor() }.also {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT,it)
        }
        if(session.isLoggedIn() && session.role=="doctor") {
            startup(savedInstanceState)
        } else login()
    }
    override fun onResume() {
        super.onResume()
        if(::root.isInitialized) displayedPalette=ThemeController.refresh(this,root,displayedPalette)
    }
    override fun onConfigurationChanged(newConfig:Configuration) {
        super.onConfigurationChanged(newConfig)
        if(::root.isInitialized) displayedPalette=ThemeController.refresh(this,root,displayedPalette)
    }
    private fun startup(saved:Bundle?=null) {
        workspaceRestore=saved?.takeIf {it.getString("workspace_identity")==identityFingerprint()}
        val box=page("医生工作台")
        button(box,"重试连接并加载队列") {startup(saved)}
        button(box,"退出医生账号") {logout()}
        task({repo.me();repo.queue()}) { rows ->
            renderQueue(rows)
            val restore=workspaceRestore
            val visit=rows.firstOrNull {it.appointment.appointmentId==(restore?.getLong("visit_id",0) ?: 0)} ?: restoredVisit(restore)
            if(visit!=null) open(visit,restore)
        }
    }
    private fun rounded(color:Int,stroke:Int?=null)=ThemeController.rounded(color,stroke,dp(HarmonyUi.CARD_RADIUS).toFloat(),dp(1))
    private fun label(value:String,size:Float=HarmonyUi.BODY)=TextView(this).apply {
        text=value;textSize=size;setTextColor(palette.ink);setPadding(0,dp(4),0,dp(4))
        if(size>=HarmonyUi.HEADING) setTypeface(typeface,Typeface.BOLD)
    }
    private fun note(value:String)=label(value,HarmonyUi.CAPTION).apply {setTextColor(palette.secondary)}
    private fun column()=LinearLayout(this).apply {
        orientation=LinearLayout.VERTICAL;setPadding(dp(HarmonyUi.PAGE_PADDING),dp(HarmonyUi.GAP),dp(HarmonyUi.PAGE_PADDING),dp(HarmonyUi.SECTION_GAP))
    }
    private fun card()=LinearLayout(this).apply {
        orientation=LinearLayout.VERTICAL;setPadding(dp(HarmonyUi.CARD_PADDING),dp(HarmonyUi.GAP),dp(HarmonyUi.CARD_PADDING),dp(HarmonyUi.CARD_PADDING))
        background=rounded(palette.surface)
    }
    private fun add(parent:LinearLayout,view:View) { parent.addView(view,LinearLayout.LayoutParams(-1,-2).apply { topMargin=dp(HarmonyUi.GAP) }) }
    private fun styleInput(input:EditText)=input.apply {
        textSize=HarmonyUi.BODY;setTextColor(palette.ink);setHintTextColor(palette.secondary)
        background=rounded(palette.surfaceAlt);backgroundTintList=null
        setPadding(dp(HarmonyUi.GAP),dp(HarmonyUi.GAP),dp(HarmonyUi.GAP),dp(HarmonyUi.GAP));minHeight=dp(HarmonyUi.CONTROL_HEIGHT)
    }
    private fun button(parent:LinearLayout,title:String,primary:Boolean=false,action:()->Unit)=Button(this).apply {
        text=title;isAllCaps=false;textSize=HarmonyUi.BODY
        setTextColor(if(primary) palette.onPrimary else palette.primaryDark)
        background=rounded(if(primary) palette.primary else palette.primarySoft)
        backgroundTintList=null;minHeight=dp(HarmonyUi.TOUCH_MIN);minimumHeight=dp(HarmonyUi.TOUCH_MIN)
        setPadding(dp(HarmonyUi.GAP),dp(8),dp(HarmonyUi.GAP),dp(8))
        setOnClickListener { if(!busy) action() }
    }.also { add(parent,it) }
    private fun chip(text:String,status:String)=label(text,HarmonyUi.CAPTION).apply {
        val colors=when(status) {
            "done","locked"->palette.success to palette.successSoft
            "cancelled","no_show"->palette.danger to palette.dangerSoft
            "visiting"->palette.primaryDark to palette.primarySoft
            else->palette.info to palette.infoSoft
        }
        setTextColor(colors.first);background=rounded(colors.second)
        setPadding(dp(HarmonyUi.GAP),dp(4),dp(HarmonyUi.GAP),dp(4));gravity=Gravity.CENTER_VERTICAL
    }
    private fun readOnlyContent(text:String)=ScrollView(this).apply {
        setBackgroundColor(palette.bg)
        addView(column().apply {add(this,card().apply {add(this,label(text).apply {setTextIsSelectable(true)})})})
    }
    private fun page(title:String): LinearLayout {
        generation++;root.removeAllViews();inputViews.clear()
        root.addView(label(title,HarmonyUi.TITLE).apply {
            gravity=Gravity.CENTER_VERTICAL;setPadding(dp(HarmonyUi.PAGE_PADDING),0,dp(HarmonyUi.PAGE_PADDING),0)
            setBackgroundColor(palette.surface)
        },LinearLayout.LayoutParams(-1,dp(HarmonyUi.HEADER_HEIGHT)))
        if(session.mockMode) add(root,note("演示模式 · 数据不会写入服务器").apply {
            setPadding(dp(HarmonyUi.PAGE_PADDING),dp(4),dp(HarmonyUi.PAGE_PADDING),dp(4));setBackgroundColor(palette.infoSoft)
        })
        message=note("").apply {
            setPadding(dp(HarmonyUi.PAGE_PADDING),dp(4),dp(HarmonyUi.PAGE_PADDING),dp(4))
            setTextColor(palette.danger);accessibilityLiveRegion=View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        add(root,message)
        val scroll=ScrollView(this);val content=column();scroll.addView(content)
        root.addView(scroll,LinearLayout.LayoutParams(-1,0,1f))
        return content
    }
    private fun identity()="${session.baseUrl}|${session.userId}|${session.token}|${session.mockMode}"
    // Bind transient saved state to this login without persisting its bearer token.
    private fun identityFingerprint()=java.security.MessageDigest.getInstance("SHA-256")
        .digest(identity().toByteArray(Charsets.UTF_8)).joinToString("") {"%02x".format(it.toInt() and 255)}
    private fun setEditorEnabled(enabled:Boolean) {
        inputViews.values.forEach {it.isEnabled=enabled && record?.locked!=true && !lockNeedsConfirmation}
    }
    private fun <T> task(work:()->T,failed:((Throwable)->Unit)?=null,done:(T)->Unit) {
        if(busy) return
        setEditorEnabled(false)
        busy=true;val expected=identity();val revision=generation;message.text="正在处理，请稍候…"
        worker.execute {
            val result=runCatching(work)
            runOnUiThread {
                if(isFinishing || isDestroyed || revision!=generation) { busy=false;return@runOnUiThread }
                busy=false
                setEditorEnabled(true)
                if(expected!=identity()) {
                    current=null;record=null;draft.clear();dirty=false;pendingSave=null;reviewRecord=null
                    lockNeedsConfirmation=false;workspaceRestore=null;workspaceIdentity=null
                    if(!session.isLoggedIn()) {login();message.text="会话已退出，请重新登录"}
                    else startup()
                    return@runOnUiThread
                }
                result.fold({ value ->
                    message.text=""
                    runCatching {done(value)}.onFailure {message.text=errorText(it)}
                },{error->if(failed!=null) failed(error) else message.text=errorText(error)})
            }
        }
    }
    private fun errorText(error:Throwable):String {
        val e=error as? ApiException
        val text=when(error) {is ApiException->error.message;is org.json.JSONException->"响应内容不完整，请重新读取并联系维护人员";is IllegalStateException->error.message ?: "当前操作未完成";is IllegalArgumentException->error.message ?: "请检查输入";else->"操作未确认，请刷新后核对"}
        return text +
            if(e?.requestId.orEmpty().isNotBlank()) "\n请求编号：${e?.requestId}" else ""
    }
    private fun login() {
        val box=page("医生工作台")
        val brand=LinearLayout(this).apply {
            orientation=LinearLayout.VERTICAL;gravity=Gravity.CENTER
            setPadding(0,dp(HarmonyUi.SECTION_GAP),0,dp(HarmonyUi.SECTION_GAP))
        }
        add(brand,label(getString(R.string.doctor_brand),HarmonyUi.DISPLAY).apply {gravity=Gravity.CENTER})
        add(brand,label(getString(R.string.doctor_role)).apply {gravity=Gravity.CENTER;setTextColor(palette.primaryDark)})
        add(brand,note(getString(R.string.doctor_login_subtitle)).apply {gravity=Gravity.CENTER})
        add(box,brand)
        val form=card();add(box,form)
        add(form,note(getString(R.string.doctor_online_service)))
        val base=EditText(this).apply { hint="服务地址";setText(session.baseUrl);isSingleLine=true }
        val name=EditText(this).apply { hint="医生账号";isSingleLine=true }
        val password=EditText(this).apply { hint="密码";inputType=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD;isSingleLine=true;isSaveEnabled=false }
        add(form,note(getString(R.string.doctor_server_label)));add(form,styleInput(base))
        add(form,note(getString(R.string.doctor_account_label)));add(form,styleInput(name))
        add(form,note(getString(R.string.doctor_password_label)));add(form,styleInput(password))
        button(form,"登录医生工作台",primary=true) {
            runCatching { session.switchMode(false);session.baseUrl=base.text.toString() }.onFailure {message.text=errorText(it);return@button}
            val loginName=name.text.toString().trim();val secret=password.text.toString()
            task({repo.login(loginName,secret)}) { session.saveLogin(it);password.text.clear();loadQueue() }
        }
        if(BuildConfig.DEBUG) button(form,"体验医生演示") {
            session.switchMode(true);session.saveLogin(repo.demoLogin());loadQueue()
        }
        button(form,"返回患者入口") { patientEntry() }
        add(box,note(getString(R.string.doctor_login_guidance)).apply {
            setTextColor(palette.info);background=rounded(palette.infoSoft)
            setPadding(dp(HarmonyUi.GAP),dp(HarmonyUi.GAP),dp(HarmonyUi.GAP),dp(HarmonyUi.GAP))
        })
    }
    private fun patientEntry() { startActivity(Intent(this,MainActivity::class.java));finish() }
    private fun loadQueue() { task({repo.queue()}) { renderQueue(it) } }
    private fun renderQueue(rows:List<DoctorVisit>) {
        current=null;record=null;dirty=false;lockNeedsConfirmation=false;pendingSave=null;reviewRecord=null;workspaceIdentity=null;draft.clear()
        val box=page("今日接诊队列")
        add(box,note("${session.displayName} · 仅显示序号与患者编号"))
        button(box,"刷新队列") { loadQueue() }
        restoredVisit(workspaceRestore)?.let { visit ->
            button(box,"恢复未完成病历（预约 #${visit.appointment.appointmentId}）") {open(visit,workspaceRestore)}
        }
        button(box,"退出医生账号") {
            logout()
        }
        if(rows.size>=200) add(box,note("当前仅显示今日前 200 条，请结合院内系统核对其余预约"))
        if(rows.isEmpty()) add(box,card().apply {
            add(this,label("暂无接诊预约",HarmonyUi.HEADING))
            add(this,note(getString(R.string.doctor_queue_empty_hint)))
        })
        rows.forEach { row ->
            val c=card();val a=row.appointment
            add(c,label("${a.seqNo} 号 · 患者 #${a.patientId}",HarmonyUi.HEADING))
            add(c,note("${a.visitDate} ${periodText(a.period)}"))
            add(c,chip(status(a.status),a.status))
            add(c,note("病历：${recordStatus(row.recordStatus)}"))
            if(row.previsitReady) add(c,chip("已提交本次预问诊","visiting"))
            button(c,"打开病历",primary=true) { open(row) }
            add(box,c)
        }
    }
    private fun open(visit:DoctorVisit, restored:Bundle?=null) {
        // Optional material cannot prevent opening the authoritative, authorized visit record.
        task({repo.record(visit.appointment.appointmentId)}) { loaded ->
            if(loaded.appointmentId!=visit.appointment.appointmentId) throw org.json.JSONException("病历预约编号不一致")
            current=visit;record=loaded;intake=null;intakeLoaded=false;intakeError=null;dirty=false;lockNeedsConfirmation=false
            history=emptyList();historyLoaded=false;historyError=null
            workspaceIdentity=identityFingerprint()
            pendingSave=null;reviewRecord=null
            draft.clear();loaded.sections.forEach { draft[it.key]=it.value }
            val saved=restored?.getString("draft")?.let {org.json.JSONObject(it)}
            if(saved!=null && restored!=null) {
                loaded.sections.forEach {draft[it.key]=saved.optString(it.key,it.value)}
                val version=restored.getLong("draft_version",-1)
                pendingSave=restored.getString("submitted")?.let {raw->
                    val submitted=org.json.JSONObject(raw)
                    PendingSave(visit.appointment.appointmentId,restored.getLong("submitted_version",-1),
                        loaded.sections.associate {it.key to submitted.getString(it.key)})
                }
                if(pendingSave!=null) reconcileSave(loaded,render=false)
                else if(restored.getBoolean("lock_pending")) {
                    // This GET confirms lock state; local text still needs review if another writer changed it.
                    if(!sameBody(loaded,draft)) reviewRecord=loaded
                } else if(restored.getBoolean("review_required") || version!=loaded.version || loaded.locked) reviewRecord=loaded
                dirty=!sameBody(loaded,draft)
            }
            workspaceRestore=null
            editor()
        }
    }
    private fun loadIntake() {
        val id=current?.appointment?.appointmentId ?: return
        currentFocus?.clearFocus()
        task({repo.intake(id)},failed={error->
            intake=null;intakeLoaded=false;intakeError=errorText(error);editor()
        }) {summary->
            intake=summary;intakeLoaded=true;intakeError=null;editor()
        }
    }
    private fun loadHistory() {
        val appointment=current?.appointment ?: return
        currentFocus?.clearFocus()
        task({repo.history(appointment.patientId,appointment.appointmentId)},failed={error->
            history=emptyList();historyLoaded=false;historyError=errorText(error);editor()
        }) {rows->
            history=rows;historyLoaded=true;historyError=null;editor()
        }
    }
    private fun editor() {
        val visit=current ?: return;val r=record ?: return;val a=visit.appointment
        val box=page("门诊病历 · ${a.seqNo} 号")
        val visitCard=card();add(box,visitCard)
        add(visitCard,label("患者 #${a.patientId}",HarmonyUi.HEADING))
        add(visitCard,chip(status(a.status),a.status))
        add(visitCard,note("保存时间：${time(r.updatedAt)} · 版本 ${r.version}"))
        val dirtyText=note(if(pendingSave!=null || reviewRecord!=null) "保存结果或版本待核对，本地输入已保留" else if(dirty) "有未保存修改" else "内容已与服务器同步");add(visitCard,dirtyText)
        button(box,"返回接诊队列") { leaveEditor() }
        button(box,"读取服务器病历并保留输入") {confirmSave()}
        val next=when(a.status) { "booked"->"arrive";"arrived"->"waiting";"waiting"->"start";"visiting"->if(r.locked) "finish" else null;else->null }
        if(next!=null && pendingSave==null && reviewRecord==null && !lockNeedsConfirmation) button(box,mapOf("arrive" to "确认到院","waiting" to "进入候诊","start" to "开始接诊","finish" to "完成就诊").getValue(next)) {
            guardDirty { task({repo.action(a.appointmentId,next);repo.queue()}) { renderQueue(it) } }
        }
        if(a.status in setOf("booked","arrived","waiting","visiting") && pendingSave==null && reviewRecord==null && !lockNeedsConfirmation) button(box,"标记爽约") {
            guardDirty { AlertDialog.Builder(ThemeController.dialogContext(this)).setMessage("确认将本次就诊标记为爽约？").setNegativeButton("返回",null)
                .setPositiveButton("确认") { _,_->task({repo.action(a.appointmentId,"no-show");repo.queue()}) {renderQueue(it)} }.show() }
        }
        val summary=intake
        val intakeCard=card();add(intakeCard,label(if(summary!=null && !summary.bound) "历史患者自述（未绑定本次预约）" else "本次患者自述（预问诊）",HarmonyUi.HEADING))
        if(summary!=null) {
            add(intakeCard,label(if(summary.bound) "已绑定本次预约 · ${time(summary.capturedAt)}" else "仅供历史参考，不代表本次预约已提交预问诊 · ${time(summary.capturedAt)}"))
            summary.sections.forEach { section ->
                add(intakeCard,label("${section.label}：${section.value}"))
            }
            add(intakeCard,label("患者自述仅供参考，需医生核实后录入病历。"))
        } else if(intakeError!=null) add(intakeCard,label("预问诊摘要读取失败：\n${intakeError}"))
        else if(intakeLoaded) add(intakeCard,label("无可用预问诊摘要：本次未提交，历史也无已完成资料。"))
        else add(intakeCard,label("摘要尚未读取，可按需加载；不影响本次病历填写与保存。"))
        button(intakeCard,if(intakeLoaded) "重新读取预问诊摘要" else if(intakeError!=null) "重试读取预问诊摘要" else "读取预问诊摘要") {loadIntake()}
        add(box,intakeCard)
        val historyCard=card();add(historyCard,label("既往已定稿病历（本人接诊，最近 5 份）",HarmonyUi.HEADING))
        if(historyError!=null) add(historyCard,label("既往病历读取失败：\n${historyError}"))
        else if(!historyLoaded) add(historyCard,label("既往病历尚未读取，可按需加载；不影响本次病历填写与保存。"))
        else if(history.isEmpty()) add(historyCard,label("暂无可查看的既往定稿病历。"))
        history.forEach {old->
            add(historyCard,label("预约 #${old.appointmentId} · ${time(old.updatedAt)}\n"+
                old.sections.filter {it.value.isNotBlank()}.joinToString("\n") {"${it.label}：${it.value}"}))
        }
        button(historyCard,if(historyLoaded) "重新读取既往病历" else if(historyError!=null) "重试读取既往病历" else "读取既往病历") {loadHistory()}
        add(box,historyCard)
        val nav=LinearLayout(this).apply {
            orientation=LinearLayout.HORIZONTAL;background=rounded(palette.surfaceAlt)
            setPadding(dp(4),dp(4),dp(4),dp(4))
        }
        val navScroll=HorizontalScrollView(this).apply {isHorizontalScrollBarEnabled=false};navScroll.addView(nav);add(box,navScroll)
        r.sections.forEach { section ->
            val c=card();add(c,label(section.label+(if(section.requiredToLock) " *" else "")+(if(section.key in r.intakeSections) " · 预填来源：患者自述" else ""),HarmonyUi.HEADING))
            val input=styleInput(EditText(this)).apply {
                setText(draft[section.key].orEmpty());gravity=Gravity.TOP;minLines=3;isEnabled=!r.locked && !lockNeedsConfirmation
                inputType=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
                filters=arrayOf(android.text.InputFilter { source,start,end,dest,dstart,dend ->
                    val existing=dest.toString();val incoming=source.subSequence(start,end).toString()
                    val left=section.maxLen-existing.codePointCount(0,dstart)-existing.codePointCount(dend,existing.length)
                    if(incoming.codePointCount(0,incoming.length)<=left) null
                    else incoming.substring(0,incoming.offsetByCodePoints(0,left.coerceAtLeast(0)))
                })
                addTextChangedListener(object:TextWatcher {
                    override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int) {}
                    override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int) { draft[section.key]=s.toString();dirty=true;dirtyText.text="有未保存修改" }
                    override fun afterTextChanged(s:Editable?) {}
                })
            };inputViews[section.key]=input;add(c,input);add(box,c)
            nav.addView(Button(this).apply {
                text=section.label;isAllCaps=false;textSize=HarmonyUi.CAPTION
                setTextColor(palette.primaryDark);background=rounded(palette.primarySoft);backgroundTintList=null
                minHeight=dp(HarmonyUi.TOUCH_MIN);minimumHeight=dp(HarmonyUi.TOUCH_MIN)
                setOnClickListener {input.requestFocus();input.parent.requestChildFocus(input,input)}
            },LinearLayout.LayoutParams(-2,dp(HarmonyUi.TOUCH_MIN)).apply {marginEnd=dp(4)})
        }
        if(pendingSave!=null || reviewRecord!=null) {
            add(box,label("本地正文已保留。先确认服务器结果，再保存或重新预览；不会自动重发或锁定。"))
            button(box,"确认保存结果（保留本地输入）") {confirmSave()}
            reviewRecord?.let {latest->button(box,"逐段核对服务器与本地正文") {review(latest)}}
        } else if(lockNeedsConfirmation) {
            add(box,label("草稿已保存，锁定结果尚未确认。请先查询服务器状态。"))
            button(box,"确认锁定结果") {confirmSave()}
        } else if(!r.locked) {
            button(box,"保存草稿",primary=true) { save(false) }
            button(box,"提交前预览") { preview() }
        } else add(box,label("病历已定稿。修订需管理员记录理由后解锁；医生账号不能自行解锁。"))
        button(box,"查看修订与解锁记录") { revisions(a.appointmentId) }
    }
    private fun sameBody(saved:DoctorRecord,values:Map<String,String>)=saved.sections.size==values.size &&
        saved.sections.all {values[it.key]==it.value}
    private fun accept(saved:DoctorRecord) { record=saved;draft.clear();saved.sections.forEach {draft[it.key]=it.value};dirty=false;lockNeedsConfirmation=false;pendingSave=null;reviewRecord=null;editor() }
    private fun save(lock:Boolean) {
        if(busy || lockNeedsConfirmation || pendingSave!=null || reviewRecord!=null) return
        if(workspaceIdentity!=identityFingerprint()) {message.text="会话已变化，请重新打开工作台";return}
        val a=current?.appointment ?: return;val r=record ?: return
        if(lock && !dirty && r.version>0) {lockSaved(a.appointmentId,r);return}
        currentFocus?.clearFocus()
        setEditorEnabled(false)
        val values=draft.toMap()
        val submitted=PendingSave(a.appointmentId,r.version,values)
        pendingSave=submitted
        task({repo.save(a.appointmentId,r.version,values)},failed={error->
            // A dropped response can follow a committed PUT. Never blindly resend its old version.
            val definitive=(error as? ApiException)?.status in setOf(400,403,404,422,429)
            if(definitive) pendingSave=null
            editor()
            message.text=(if(definitive) "本次保存被拒绝，本地输入已保留。\n" else "保存结果尚未确认，本地输入已保留。请确认服务器结果。\n")+errorText(error)
        }) { saved ->
            if(saved.appointmentId!=submitted.appointmentId || saved.version!=submitted.version+1 ||
                saved.locked || !sameBody(saved,submitted.values)) {
                editor();message.text="保存响应与本次提交不一致，请读取服务器结果后核对；不会自动锁定。"
                return@task
            }
            accept(saved)
            if(lock) lockSaved(a.appointmentId,saved)
        }
    }
    private fun confirmSave() {
        val id=current?.appointment?.appointmentId ?: return
        task({repo.record(id)}) {latest->reconcileSave(latest)}
    }
    private fun reconcileSave(latest:DoctorRecord,render:Boolean=true) {
        if(latest.appointmentId!=current?.appointment?.appointmentId) {
            if(render) message.text="服务器返回了不同预约的病历，本地输入未被替换，请联系维护人员。"
            return
        }
        val submitted=pendingSave
        if(submitted!=null && latest.appointmentId==submitted.appointmentId && latest.version>submitted.version && sameBody(latest,submitted.values)) {
            // Confirmation establishes an equivalent authoritative body, never ownership of a later lock.
            record=latest;pendingSave=null;reviewRecord=null;lockNeedsConfirmation=false
            dirty=!sameBody(latest,draft)
            if(latest.locked && dirty) reviewRecord=latest
            if(render) {editor();message.text="已确认先前正文已保存。之后输入仍保留；定稿请重新核对预览。"}
        } else if(submitted==null && sameBody(latest,draft)) {
            record=latest;dirty=false;reviewRecord=null;lockNeedsConfirmation=false
            if(render) {editor();message.text="已读取服务器状态，正文一致。"}
        } else {
            reviewRecord=latest;lockNeedsConfirmation=false
            if(render) {editor();message.text="服务器正文或版本需要核对，本地输入未被替换。"}
        }
    }
    private fun review(latest:DoctorRecord) {
        val text="服务器版本 ${latest.version}${if(latest.locked) "（已定稿）" else ""}。核对后再决定继续编辑的版本。\n\n"+
            latest.sections.joinToString("\n\n") {"${it.label}\n服务器：${it.value}\n本地：${draft[it.key].orEmpty()}"}
        val content=label(text).apply {setTextIsSelectable(true)}
        val scroll=ScrollView(this).apply {addView(content)}
        val dialog=AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle("逐段核对 · 本地输入保留").setView(scroll).setNegativeButton("继续核对",null)
        if(!latest.locked) dialog.setPositiveButton("保留本地，以此版本继续编辑") {_,_->
            record=latest;pendingSave=null;reviewRecord=null;lockNeedsConfirmation=false;dirty=!sameBody(latest,draft);editor()
            message.text="已保留本地正文；下次保存将校验版本 ${latest.version}，定稿仍需重新预览。"
        }
        dialog.setNeutralButton("采用服务器正文") {_,_->
            AlertDialog.Builder(ThemeController.dialogContext(this)).setMessage("这会放弃当前本地输入并采用服务器正文，确认继续？")
                .setNegativeButton("保留本地",null).setPositiveButton("采用服务器正文") {_,_->accept(latest)}.show()
        }.show()
    }
    private fun lockSaved(id:Long,saved:DoctorRecord) {
        lockNeedsConfirmation=true
        task({repo.lock(id,saved.version)},failed={error->
            editor()
            message.text="草稿已保存（版本 ${saved.version}），锁定结果尚未确认。\n"+errorText(error)
        }) {locked->
            if(locked.appointmentId==id && locked.locked && locked.version==saved.version+1 && sameBody(locked,saved.sections.associate {it.key to it.value})) accept(locked)
            else {editor();message.text="锁定响应与本次正文不一致，请确认服务器状态；本地正文已保留。"}
        }
    }
    private fun preview() {
        if(pendingSave!=null || reviewRecord!=null || lockNeedsConfirmation) return
        val r=record ?: return
        val missing=r.sections.filter {it.requiredToLock && draft[it.key].isNullOrBlank()}
        if(missing.isNotEmpty()) {message.text="请先填写："+missing.joinToString {it.label};return}
        AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle("提交前预览 · 定稿后不可直接编辑")
            .setMessage(r.sections.joinToString("\n\n") {"${it.label}${if(it.key in r.intakeSections) "（预填来源：患者自述）" else ""}\n${draft[it.key].orEmpty()}"})
            .setNegativeButton("返回修改",null).setPositiveButton("保存并锁定") {_,_->save(true)}.show()
    }
    private fun revisions(id:Long) {
        currentFocus?.clearFocus()
        task({repo.revisions(id)},failed={error->
            message.text=if((error as? ApiException)?.status==403) "当前医生账号无权读取修订记录。\n"+errorText(error) else errorText(error)
        }) { data ->
            val a=data.getJSONArray("items")
            // The server lists events ascending; display newest first and compare the last pair.
            val versions=(0 until a.length()).map {a.getJSONObject(it)}.sortedBy {it.getLong("version")}
            val text=versions.asReversed().joinToString("\n\n") {v->
                val operation=when(v.getString("operation")) {"lock"->"定稿";"reopen"->"解锁";else->v.getString("operation")}
                "版本 ${v.getLong("version")} · $operation · 操作者 #${v.getLong("operator_user_id")} · ${time(v.getLong("created_at"))}"+
                    v.optString("reason").takeIf {it.isNotBlank()}?.let {"\n理由：$it"}.orEmpty()
            }
            val dialog=AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle("病历定稿与解锁记录").setView(readOnlyContent(text.ifBlank {"暂无修订记录"})).setNegativeButton("关闭",null)
            if(versions.size>=2) dialog.setPositiveButton("对比最近两版") {_,_->
                val latest=versions.last().getLong("version");val previous=versions[versions.lastIndex-1].getLong("version")
                task({repo.diff(id,latest,previous)},failed={error->
                    message.text=if((error as? ApiException)?.status==403) "当前医生账号无权读取版本差异。\n"+errorText(error) else errorText(error)
                }) {diff->
                    val rows=diff.getJSONArray("sections")
                    val content=(0 until rows.length()).joinToString("\n\n") {i->val v=rows.getJSONObject(i);"${v.getString("label")}：${if(v.getBoolean("changed")) "已修改" else "未修改"}\n之前：${v.getString("left")}\n之后：${v.getString("right")}"}
                    AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle("病历修订对比").setView(readOnlyContent(content)).setPositiveButton("关闭",null).show()
                }
            };dialog.show()
        }
    }
    private fun guardDirty(action:()->Unit) {
        if(!dirty && pendingSave==null && reviewRecord==null && !lockNeedsConfirmation) action()
        else AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle("有未保存输入或待确认结果")
            .setMessage("离开会放弃当前本地输入与结果确认记录。可留在本页确认服务器结果，是否离开？")
            .setNegativeButton("留在本页",null).setPositiveButton("放弃本地记录并离开") {_,_->
                dirty=false;pendingSave=null;reviewRecord=null;lockNeedsConfirmation=false;workspaceRestore=null;action()
            }.show()
    }
    private fun leaveEditor() {
        if(busy) return
        if(current!=null) guardDirty {loadQueue()} else if(session.isLoggedIn()) finish() else patientEntry()
    }
    private fun logout() {
        if(busy) return
        busy=true;val revision=generation
        worker.execute {
            val result=runCatching {repo.logout()}
            runOnUiThread {
                busy=false
                if(isFinishing || isDestroyed || revision!=generation || session.isLoggedIn()) return@runOnUiThread
                current=null;record=null;draft.clear();dirty=false;pendingSave=null;reviewRecord=null;workspaceRestore=null;login()
                message.text=result.fold({"已退出医生账号"},{"本设备已退出，服务器注销尚未确认。\n"+errorText(it)})
            }
        }
    }
    @Deprecated("Legacy Android back callback") override fun onBackPressed()=leaveEditor()
    override fun onDestroy() {
        if(Build.VERSION.SDK_INT>=33) backCallback?.let {onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it)}
        worker.shutdownNow();super.onDestroy()
    }
    override fun onSaveInstanceState(outState:Bundle) {
        // Keep a startup recovery snapshot across another rotation even while reconnecting.
        workspaceRestore?.let {outState.putAll(it)}
        val visit=current
        if(visit!=null && workspaceIdentity==identityFingerprint()) {
            outState.putString("workspace_identity",identityFingerprint())
            outState.putLong("visit_id",visit.appointment.appointmentId)
            outState.putString("visit_context",visitJson(visit))
            outState.putLong("draft_version",record?.version ?: -1)
            outState.putString("draft",org.json.JSONObject(draft.toMap()).toString())
            outState.putBoolean("lock_pending",lockNeedsConfirmation)
            outState.putBoolean("review_required",reviewRecord!=null)
            pendingSave?.let {submitted->
                outState.putLong("submitted_version",submitted.version)
                outState.putString("submitted",org.json.JSONObject(submitted.values).toString())
            }
        }
        super.onSaveInstanceState(outState)
    }
    private fun visitJson(visit:DoctorVisit):String {
        val a=visit.appointment
        return org.json.JSONObject().put("appointment_id",a.appointmentId).put("schedule_id",a.scheduleId)
            .put("patient_id",a.patientId).put("doctor_id",a.doctorId).put("department_id",a.departmentId)
            .put("visit_date",a.visitDate).put("period",a.period).put("seq_no",a.seqNo).put("status",a.status)
            .put("previsit_ready",visit.previsitReady).put("record_status",visit.recordStatus).put("record_filled",visit.recordFilled).toString()
    }
    private fun restoredVisit(saved:Bundle?):DoctorVisit? {
        if(saved?.getString("workspace_identity")!=identityFingerprint()) return null
        return saved?.getString("visit_context")?.let {raw->runCatching {
            val o=org.json.JSONObject(raw)
            DoctorVisit(ContractParser.appointment(o),o.optString("record_status"),o.optInt("record_filled"),o.optBoolean("previsit_ready"))
        }.getOrNull()}
    }
    private fun time(seconds:Long)=if(seconds<=0) "尚未保存" else SimpleDateFormat("yyyy-MM-dd HH:mm:ss",Locale.CHINA)
        .apply {timeZone=java.util.TimeZone.getTimeZone("Asia/Shanghai")}.format(Date(seconds*1000))
    private fun status(s:String)=mapOf("booked" to "已挂号","arrived" to "已到院","waiting" to "候诊中","visiting" to "接诊中","done" to "已完成","cancelled" to "已退号","no_show" to "已爽约")[s] ?: s
    private fun periodText(s:String)=when(s) {"AM"->getString(R.string.doctor_period_morning);"PM"->getString(R.string.doctor_period_afternoon);else->s}
    private fun recordStatus(s:String)=when(s) {"draft"->"草稿";"locked"->"已定稿";"none","empty",""->"待填写";else->s}
}
