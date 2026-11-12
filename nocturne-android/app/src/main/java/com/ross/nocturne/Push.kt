package com.ross.nocturne

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

const val CHANNEL_MESSAGES = "messages"
const val CHANNEL_CALLS = "calls"

class NocturneApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "New messages"
            enableVibration(true)
        })
        nm.createNotificationChannel(NotificationChannel(CHANNEL_CALLS, "Calls", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Incoming video calls"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 800, 600, 800, 600, 800)
            setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build(),
            )
        })
    }
}

object PushRegistration {
    /** Sends this phone's Firebase token to the server so messages and calls can reach it when closed. */
    fun sync(ctx: Context) {
        val prefs = Prefs(ctx)
        if (!BuildConfig.HAS_FIREBASE || !prefs.signedIn || FirebaseApp.getApps(ctx).isEmpty()) return
        FirebaseMessaging.getInstance().token.addOnSuccessListener { tok ->
            CoroutineScope(Dispatchers.IO).launch {
                runCatching { Api(prefs).registerPush(tok); prefs.pushToken = tok }
                    .onFailure { Log.w("Nocturne", "push register failed: ${it.message}") }
            }
        }
    }
}

class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        val prefs = Prefs(this)
        if (!prefs.signedIn) return
        CoroutineScope(Dispatchers.IO).launch { runCatching { Api(prefs).registerPush(token); prefs.pushToken = token } }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val d = message.data
        val room = d["room"] ?: return
        val title = d["title"] ?: "Nocturne"
        if (d["kind"] == "call") Notifier.incomingCall(this, room, title)
        else Notifier.message(this, room, title, d["body"] ?: "")
    }
}

object Notifier {
    private fun id(room: String, call: Boolean) = room.hashCode() * 2 + if (call) 1 else 0

    private fun open(ctx: Context, uri: String, req: Int): PendingIntent {
        val i = Intent(Intent.ACTION_VIEW, Uri.parse(uri), ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(ctx, req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun message(ctx: Context, room: String, title: String, body: String) {
        if (MainActivity.visibleRoom == room) return // already reading this conversation
        val n = Notification.Builder(ctx, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_nocturne)
            .setColor(0xFFC01030.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(open(ctx, "nocturne://chat/$room", id(room, false)))
            .build()
        ctx.getSystemService(NotificationManager::class.java).notify(id(room, false), n)
    }

    fun incomingCall(ctx: Context, room: String, title: String) {
        val answer = open(ctx, "nocturne://call/$room?incoming=1", id(room, true))
        val decline = PendingIntent.getBroadcast(
            ctx, id(room, true), Intent(ctx, DeclineReceiver::class.java).putExtra("room", room),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(ctx, CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat_nocturne)
            .setColor(0xFFC01030.toInt())
            .setContentTitle(title)
            .setContentText("Video call — tap to answer")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(true)
            .setTimeoutAfter(60_000)
            .setContentIntent(answer)
            .setFullScreenIntent(answer, true)
            .addAction(Notification.Action.Builder(null, "Decline", decline).build())
            .addAction(Notification.Action.Builder(null, "Answer", answer).build())
            .build()
        n.flags = n.flags or Notification.FLAG_INSISTENT // keep ringing until answered, declined or timed out
        ctx.getSystemService(NotificationManager::class.java).notify(id(room, true), n)
    }

    fun clear(ctx: Context, room: String, call: Boolean = false) {
        ctx.getSystemService(NotificationManager::class.java).cancel(id(room, call))
    }
}

class DeclineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Notifier.clear(context, intent.getStringExtra("room") ?: return, call = true)
    }
}
