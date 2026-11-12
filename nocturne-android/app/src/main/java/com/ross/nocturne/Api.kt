package com.ross.nocturne

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** Sign-in details and small bits of state, kept in the app's private storage. */
class Prefs(ctx: Context) {
    private val p = ctx.getSharedPreferences("nocturne", Context.MODE_PRIVATE)

    var server: String
        get() = p.getString("server", "") ?: ""
        set(v) = p.edit().putString("server", normalize(v)).apply()
    var token: String
        get() = p.getString("token", "") ?: ""
        set(v) = p.edit().putString("token", v.trim()).apply()
    var myName: String
        get() = p.getString("name", "") ?: ""
        set(v) = p.edit().putString("name", v).apply()
    var pushToken: String
        get() = p.getString("pushToken", "") ?: ""
        set(v) = p.edit().putString("pushToken", v).apply()

    val signedIn get() = server.isNotBlank() && token.isNotBlank()

    fun lastSeen(room: String): Long = p.getLong("seen_$room", 0)
    fun markSeen(room: String, id: Long) {
        if (id > lastSeen(room)) p.edit().putLong("seen_$room", id).apply()
    }

    fun signOut() = p.edit().clear().apply()

    companion object {
        fun normalize(raw: String): String {
            var s = raw.trim()
            if (s.isEmpty()) return ""
            if (!s.startsWith("http://", true) && !s.startsWith("https://", true)) s = "https://$s"
            return s.trimEnd('/')
        }
    }
}

data class Room(
    val id: String, val title: String,
    val lastId: Long, val lastSender: String, val lastText: String, val lastTs: Double,
)
data class Msg(val id: Long, val sender: String, val text: String, val ts: Double)
data class Me(val name: String, val rooms: List<Room>)

class ApiException(val code: Int, message: String) : Exception(message)

/** Talks to the Nocturne server. Every call blocks: run them on Dispatchers.IO. */
class Api(private val prefs: Prefs) {

    private fun request(method: String, path: String, body: JSONObject? = null): String {
        val conn = URL(prefs.server + path).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 15_000
        conn.readTimeout = 20_000
        conn.setRequestProperty("Authorization", "Bearer ${prefs.token}")
        if (body != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val code = conn.responseCode
        val text = (if (code in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
        conn.disconnect()
        if (code !in 200..299) {
            throw ApiException(code, when (code) {
                401 -> "This sign-in isn't valid any more. Open your invitation link again."
                403 -> "That conversation isn't yours."
                else -> "The server said $code."
            })
        }
        return text
    }

    fun me(): Me {
        val o = JSONObject(request("GET", "/api/me"))
        val arr = o.optJSONArray("rooms") ?: JSONArray()
        val rooms = (0 until arr.length()).map { i ->
            val r = arr.getJSONObject(i)
            val last = r.optJSONObject("last")
            Room(
                id = r.getString("id"), title = r.optString("title", r.getString("id")),
                lastId = last?.optLong("id") ?: 0, lastSender = last?.optString("sender") ?: "",
                lastText = last?.optString("text") ?: "", lastTs = last?.optDouble("ts") ?: 0.0,
            )
        }
        return Me(o.optString("name"), rooms)
    }

    fun messages(room: String, since: Long): List<Msg> {
        val arr = JSONArray(request("GET", "/api/relay/messages?room=${enc(room)}&since=$since"))
        return (0 until arr.length()).map { i ->
            val m = arr.getJSONObject(i)
            Msg(m.getLong("id"), m.optString("sender"), m.optString("text"), m.optDouble("ts"))
        }
    }

    fun send(room: String, text: String) {
        request("POST", "/api/relay/send", JSONObject().put("room", room).put("text", text))
    }

    fun ring(room: String) {
        request("POST", "/api/call/ring", JSONObject().put("room", room))
    }

    fun registerPush(fcmToken: String) {
        request("POST", "/api/push/register", JSONObject().put("token", fcmToken).put("platform", "android"))
    }

    fun callUrl(room: String, with: String): String =
        "${prefs.server}/call?room=${enc(room)}&name=${enc(prefs.myName)}&with=${enc(with)}&token=${enc(prefs.token)}"

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
}
