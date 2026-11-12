package com.ross.nocturne

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Call
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object C {
    val bg = Color(0xFF0A0506)
    val panel = Color(0xFF1A1013)
    val field = Color(0xFF241319)
    val crimson = Color(0xFFC01030)
    val rose = Color(0xFFE8415C)
    val text = Color(0xFFF0E6E8)
    val muted = Color(0xFF9A8288)
    val answer = Color(0xFF2E9E5B)
}

sealed interface Screen {
    data object SignIn : Screen
    data object Rooms : Screen
    data class Chat(val room: Room) : Screen
    data class Incoming(val room: Room) : Screen
    data class Call(val room: Room) : Screen
}

class MainActivity : ComponentActivity() {
    companion object {
        /** The conversation currently on screen, so its notifications are skipped. */
        @Volatile var visibleRoom: String? = null
    }

    private val pendingLink = mutableStateOf<Uri?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLink.value = intent?.data
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = C.crimson, background = C.bg, surface = C.panel)) {
                Surface(Modifier.fillMaxSize(), color = C.bg) { App(this, pendingLink) }
            }
        }
        PushRegistration.sync(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingLink.value = intent.data
    }

    /** Lets an incoming call show over the lock screen and keeps the screen on during calls. */
    fun callMode(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        }
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

@Composable
fun App(activity: MainActivity, pendingLink: MutableState<Uri?>) {
    val prefs = remember { Prefs(activity) }
    val api = remember { Api(prefs) }
    val scope = rememberCoroutineScope()
    var screen by remember { mutableStateOf<Screen>(if (prefs.signedIn) Screen.Rooms else Screen.SignIn) }
    var rooms by remember { mutableStateOf<List<Room>>(emptyList()) }
    var error by remember { mutableStateOf("") }

    suspend fun refreshRooms(): List<Room> {
        val me = withContext(Dispatchers.IO) { runCatching { api.me() } }
        me.onSuccess { prefs.myName = it.name; rooms = it.rooms; error = "" }
            .onFailure { error = it.message ?: "Can't reach the server." }
        return rooms
    }

    fun roomById(id: String) = rooms.firstOrNull { it.id == id } ?: Room(id, id, 0, "", "", 0.0)

    // Deep links: sign-in from the join page, and taps on notifications.
    LaunchedEffect(pendingLink.value) {
        val uri = pendingLink.value ?: return@LaunchedEffect
        pendingLink.value = null
        if (uri.scheme != "nocturne") return@LaunchedEffect
        val target = uri.pathSegments.firstOrNull()
        when (uri.host) {
            "setup" -> {
                prefs.server = uri.getQueryParameter("server") ?: ""
                prefs.token = uri.getQueryParameter("token") ?: ""
                val list = refreshRooms()
                if (error.isEmpty()) {
                    PushRegistration.sync(activity)
                    screen = if (list.size == 1) Screen.Chat(list[0]) else Screen.Rooms
                } else screen = Screen.SignIn
            }
            "chat" -> if (prefs.signedIn && target != null) { refreshRooms(); screen = Screen.Chat(roomById(target)) }
            "call" -> if (prefs.signedIn && target != null) {
                refreshRooms()
                Notifier.clear(activity, target, call = true)
                screen = if (uri.getQueryParameter("incoming") == "1") Screen.Incoming(roomById(target)) else Screen.Call(roomById(target))
            }
        }
    }

    LaunchedEffect(screen) {
        activity.callMode(screen is Screen.Call || screen is Screen.Incoming)
        if (screen == Screen.Rooms) {
            val list = refreshRooms()
            if (list.size == 1 && error.isEmpty()) screen = Screen.Chat(list[0]) // one conversation: go straight in
        }
    }

    when (val s = screen) {
        Screen.SignIn -> SignInScreen(prefs, error) { server, token ->
            prefs.server = server; prefs.token = token
            scope.launch {
                val list = refreshRooms()
                if (error.isEmpty()) {
                    PushRegistration.sync(activity)
                    screen = if (list.size == 1) Screen.Chat(list[0]) else Screen.Rooms
                }
            }
        }
        Screen.Rooms -> RoomsScreen(prefs, rooms, error,
            onOpen = { screen = Screen.Chat(it) },
            onRefresh = { scope.launch { refreshRooms() } },
            onSignOut = { prefs.signOut(); rooms = emptyList(); screen = Screen.SignIn })
        is Screen.Chat -> {
            BackHandler(enabled = rooms.size > 1) { screen = Screen.Rooms }
            ChatScreen(activity, api, prefs, s.room, showBack = rooms.size > 1,
                onBack = { screen = Screen.Rooms },
                onCall = { scope.launch(Dispatchers.IO) { runCatching { api.ring(s.room.id) } }; screen = Screen.Call(s.room) })
        }
        is Screen.Incoming -> IncomingScreen(s.room,
            onAnswer = { screen = Screen.Call(s.room) },
            onDecline = { screen = Screen.Chat(s.room) })
        is Screen.Call -> {
            BackHandler { screen = Screen.Chat(s.room) }
            CallScreen(api, s.room) { screen = Screen.Chat(s.room) }
        }
    }
}

// ---------------------------------------------------------------- sign in

@Composable
fun SignInScreen(prefs: Prefs, error: String, onSignIn: (String, String) -> Unit) {
    var manual by remember { mutableStateOf(false) }
    var server by remember { mutableStateOf(prefs.server) }
    var token by remember { mutableStateOf(prefs.token) }
    Column(Modifier.fillMaxSize().padding(28.dp).systemBarsPadding(), verticalArrangement = Arrangement.Center) {
        Text("Nocturne", color = C.rose, fontSize = 40.sp, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Text("To sign in, open the invitation link you were sent and tap \"Open Nocturne and sign in\".",
            color = C.text, fontSize = 19.sp, lineHeight = 27.sp)
        if (error.isNotEmpty()) {
            Spacer(Modifier.height(16.dp)); Text(error, color = C.rose, fontSize = 16.sp)
        }
        Spacer(Modifier.height(28.dp))
        if (!manual) {
            TextButton(onClick = { manual = true }) { Text("Enter the details by hand", color = C.muted) }
        } else {
            OutlinedTextField(server, { server = it }, label = { Text("Server") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(token, { token = it }, label = { Text("Token") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(16.dp))
            Button(onClick = { onSignIn(server, token) }, enabled = server.isNotBlank() && token.isNotBlank(),
                colors = ButtonDefaults.buttonColors(containerColor = C.crimson)) { Text("Sign in", fontSize = 17.sp) }
        }
    }
}

// ---------------------------------------------------------------- conversation list

@Composable
fun RoomsScreen(prefs: Prefs, rooms: List<Room>, error: String, onOpen: (Room) -> Unit, onRefresh: () -> Unit, onSignOut: () -> Unit) {
    var confirmSignOut by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { while (true) { delay(10_000); onRefresh() } }
    Column(Modifier.fillMaxSize().systemBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(20.dp, 18.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Messages", color = C.rose, fontSize = 30.sp, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f))
            TextButton(onClick = { confirmSignOut = true }) { Text("Sign out", color = C.muted) }
        }
        if (error.isNotEmpty()) Text(error, color = C.rose, modifier = Modifier.padding(horizontal = 20.dp))
        LazyColumn(Modifier.fillMaxSize()) {
            items(rooms, key = { it.id }) { r ->
                val unread = r.lastId > prefs.lastSeen(r.id) && r.lastSender != prefs.myName
                Row(Modifier.fillMaxWidth().clickable { onOpen(r) }.padding(20.dp, 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(48.dp).clip(CircleShape).background(C.crimson.copy(alpha = 0.25f)), contentAlignment = Alignment.Center) {
                        Text(r.title.take(1).uppercase(), color = C.rose, fontSize = 22.sp, fontFamily = FontFamily.Serif)
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(r.title, color = C.text, fontSize = 19.sp, fontWeight = if (unread) FontWeight.Bold else FontWeight.Medium)
                        Text(if (r.lastText.isEmpty()) "No messages yet" else r.lastText, color = if (unread) C.text else C.muted,
                            fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    if (unread) Box(Modifier.size(12.dp).clip(CircleShape).background(C.rose))
                }
            }
        }
    }
    if (confirmSignOut) AlertDialog(
        onDismissRequest = { confirmSignOut = false },
        confirmButton = { TextButton(onClick = { confirmSignOut = false; onSignOut() }) { Text("Sign out", color = C.rose) } },
        dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
        title = { Text("Sign out?") },
        text = { Text("You'll need your invitation link to sign back in.") },
    )
}

// ---------------------------------------------------------------- chat

@Composable
fun ChatScreen(activity: MainActivity, api: Api, prefs: Prefs, room: Room, showBack: Boolean, onBack: () -> Unit, onCall: () -> Unit) {
    val messages = remember(room.id) { mutableStateListOf<Msg>() }
    var draft by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()

    suspend fun poll() {
        val since = messages.lastOrNull()?.id ?: 0
        withContext(Dispatchers.IO) { runCatching { api.messages(room.id, since) } }
            .onSuccess { new ->
                status = ""
                if (new.isNotEmpty()) {
                    messages.addAll(new.filter { n -> messages.none { it.id == n.id } })
                    prefs.markSeen(room.id, messages.last().id)
                }
            }
            .onFailure { status = it.message ?: "Can't reach the server." }
    }

    DisposableEffect(room.id) {
        MainActivity.visibleRoom = room.id
        Notifier.clear(activity, room.id)
        onDispose { MainActivity.visibleRoom = null }
    }
    LaunchedEffect(room.id) { while (true) { poll(); delay(3_000) } }
    LaunchedEffect(messages.size) { if (messages.isNotEmpty()) list.animateScrollToItem(messages.size - 1) }

    Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(8.dp, 10.dp), verticalAlignment = Alignment.CenterVertically) {
            if (showBack) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = C.text) }
            else Spacer(Modifier.width(12.dp))
            Text(room.title, color = C.rose, fontSize = 26.sp, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            IconButton(onClick = onCall) { Icon(Icons.Filled.Call, "Video call", tint = C.rose, modifier = Modifier.size(28.dp)) }
        }
        if (status.isNotEmpty()) Text(status, color = C.muted, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp))
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(12.dp)) {
            items(messages, key = { it.id }) { m -> Bubble(m, mine = m.sender == prefs.myName) }
        }
        Row(Modifier.fillMaxWidth().background(C.bg).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            TextField(draft, { draft = it }, placeholder = { Text("Message", color = C.muted) },
                modifier = Modifier.weight(1f).clip(RoundedCornerShape(22.dp)), maxLines = 5,
                textStyle = LocalTextStyle.current.copy(fontSize = 18.sp, color = C.text),
                colors = TextFieldDefaults.colors(focusedContainerColor = C.field, unfocusedContainerColor = C.field,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, cursorColor = C.rose))
            Spacer(Modifier.width(8.dp))
            IconButton(enabled = draft.isNotBlank() && !sending, onClick = {
                val text = draft.trim(); draft = ""; sending = true
                scope.launch {
                    withContext(Dispatchers.IO) { runCatching { api.send(room.id, text) } }
                        .onFailure { draft = text; status = "Not sent — ${it.message}" }
                    sending = false
                    poll()
                }
            }, modifier = Modifier.size(52.dp).clip(CircleShape).background(if (draft.isBlank()) C.panel else C.crimson)) {
                Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color.White)
            }
        }
    }
}

private val timeFmt = SimpleDateFormat("EEE HH:mm", Locale.UK)

@Composable
fun Bubble(m: Msg, mine: Boolean) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        Box(
            Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(18.dp))
                .background(if (mine) C.crimson else C.panel)
                .then(if (mine) Modifier else Modifier.border(1.dp, C.crimson.copy(alpha = 0.3f), RoundedCornerShape(18.dp)))
                .padding(14.dp, 10.dp)
        ) { Text(m.text, color = if (mine) Color.White else C.text, fontSize = 18.sp, fontFamily = FontFamily.Serif, lineHeight = 24.sp) }
        Text(timeFmt.format(Date((m.ts * 1000).toLong())), color = C.muted, fontSize = 11.sp, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

// ---------------------------------------------------------------- calls

@Composable
fun IncomingScreen(room: Room, onAnswer: () -> Unit, onDecline: () -> Unit) {
    Column(Modifier.fillMaxSize().systemBarsPadding().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.SpaceBetween) {
        Spacer(Modifier.height(40.dp))
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(120.dp).clip(CircleShape).background(C.crimson.copy(alpha = 0.25f)), contentAlignment = Alignment.Center) {
                Text(room.title.take(1).uppercase(), color = C.rose, fontSize = 54.sp, fontFamily = FontFamily.Serif)
            }
            Spacer(Modifier.height(20.dp))
            Text(room.title, color = C.text, fontSize = 32.sp, fontFamily = FontFamily.Serif)
            Text("Video call", color = C.muted, fontSize = 18.sp)
        }
        Row(Modifier.fillMaxWidth().padding(bottom = 30.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
            RoundAction("Decline", C.crimson, onDecline)
            RoundAction("Answer", C.answer, onAnswer)
        }
    }
}

@Composable
fun RoundAction(label: String, color: Color, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(78.dp).clip(CircleShape).background(color).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Call, label, tint = Color.White, modifier = Modifier.size(34.dp))
        }
        Spacer(Modifier.height(8.dp)); Text(label, color = C.text, fontSize = 16.sp)
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun CallScreen(api: Api, room: Room, onEnd: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val needed = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
    var granted by remember {
        mutableStateOf(needed.all { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED })
    }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        granted = res.values.all { it }
    }
    LaunchedEffect(Unit) { if (!granted) ask.launch(needed) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (granted) {
            val url = remember { api.callUrl(room.id, room.title) }
            AndroidView(modifier = Modifier.fillMaxSize().systemBarsPadding(), factory = { c ->
                WebView(c).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.mediaPlaybackRequiresUserGesture = false
                    webViewClient = WebViewClient()
                    webChromeClient = object : WebChromeClient() {
                        override fun onPermissionRequest(request: PermissionRequest) = request.grant(request.resources)
                    }
                    loadUrl(url)
                }
            }, onRelease = { it.loadUrl("about:blank"); it.destroy() })
        } else {
            Text("Nocturne needs the camera and microphone for video calls.", color = C.text, fontSize = 18.sp,
                modifier = Modifier.align(Alignment.Center).padding(32.dp))
        }
        Button(onClick = onEnd, colors = ButtonDefaults.buttonColors(containerColor = C.crimson),
            modifier = Modifier.align(Alignment.BottomCenter).systemBarsPadding().padding(bottom = 24.dp)) {
            Text("End call", fontSize = 18.sp)
        }
    }
}
