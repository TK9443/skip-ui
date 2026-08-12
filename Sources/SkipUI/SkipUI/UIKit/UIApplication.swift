// Copyright 2023–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import Foundation
import OSLog
#if SKIP
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.core.app.ActivityCompat
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.registerForActivityResult
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine
import java.lang.ref.WeakReference
#endif

let logger: Logger = Logger(subsystem: "skip.ui", category: "SkipUI") // adb logcat '*:S' 'skip.ui.SkipUI:V'

// SKIP @bridge
/* @MainActor */ public class UIApplication /* : UIResponder */ {
    // SKIP @bridge
    public static let shared = UIApplication()
    #if SKIP
    private var requestPermissionLauncher: ActivityResultLauncher<String>?
    private let waitingContinuations: MutableList<Continuation<Bool>> = mutableListOf<Continuation<Bool>>()
    private var startActivityLauncher: ActivityResultLauncher<Intent>?
    private let activityResultContinuations: MutableList<Continuation<ActivityResult>> = mutableListOf<Continuation<ActivityResult>>()
    #endif

    private init() {
        #if SKIP
        let lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(UIApplicationLifecycleEventObserver(application: self))
        #endif
    }

    #if SKIP
    /// The Android main activity.
    ///
    /// This API mirrors `ProcessInfo.androidContext` for the application context.
    ///
    // SKIP @bridge
    public private(set) var androidActivity: androidx.activity.ComponentActivity? {
        get {
            let activity = androidActivityReference?.get()
            return activity?.isDestroyed == false ? activity : nil
        }
        set {
            if let newValue {
                androidActivityReference = WeakReference(newValue)
            } else {
                androidActivityReference = nil
            }
            if isIdleTimerDisabled {
                setWindowFlagsForIsIdleTimerDisabled()
            }
        }
    }
    private var androidActivityReference: WeakReference<androidx.activity.ComponentActivity>?

    /// Setup the Android main activity.
    ///
    /// This API mirrors `ProcessInfo.launch` for the application context.
    public static func launch(_ activity: androidx.activity.ComponentActivity) {
        if activity !== shared.androidActivity {
            shared.androidActivity = activity

            // Must registerForActivityResult on or before Activity.onCreate
            do {
                let contract = ActivityResultContracts.RequestPermission()
                shared.requestPermissionLauncher = activity.registerForActivityResult(contract) { isGranted in
                    var continuations: ArrayList<Continuation<Bool>>? = nil
                    synchronized (shared.waitingContinuations) {
                        continuations = ArrayList(shared.waitingContinuations)
                        shared.waitingContinuations.clear()
                    }
                    continuations?.forEach { $0.resume(isGranted) }
                }
                logger.info("requestPermissionLauncher: \(shared.requestPermissionLauncher)")
            } catch {
                android.util.Log.w("SkipUI", "error initializing permission launcher", error as? Throwable)
            }

            // A second launcher, for arbitrary intents. `registerForActivityResult` has to happen on or
            // before `onCreate`, and app code never runs that early, so every activity-result flow an app
            // needs has to have its launcher registered here. `StartActivityForResult` is the one contract
            // that subsumes all the others — every `ActivityResultContract` is ultimately an intent in and
            // a result code plus intent out — so registering it once is enough for document picking,
            // document creation, photo picking and device-credential confirmation alike.
            do {
                let intentContract = ActivityResultContracts.StartActivityForResult()
                shared.startActivityLauncher = activity.registerForActivityResult(intentContract) { result in
                    var continuations: ArrayList<Continuation<ActivityResult>>? = nil
                    synchronized (shared.activityResultContinuations) {
                        continuations = ArrayList(shared.activityResultContinuations)
                        shared.activityResultContinuations.clear()
                    }
                    continuations?.forEach { $0.resume(result) }
                }
                logger.info("startActivityLauncher: \(shared.startActivityLauncher)")
            } catch {
                android.util.Log.w("SkipUI", "error initializing activity result launcher", error as? Throwable)
            }
        }
    }

    func onActivityDestroy() {
        // The permission launcher appears to hold a strong reference to the activity, so we must nil it to avoid memory leaks
        self.requestPermissionLauncher = nil
        self.startActivityLauncher = nil
    }

    /// Start the given intent and wait for its result.
    ///
    /// This is the general-purpose activity-result entry point. The launcher behind it is registered in
    /// `launch(_:)`, since Android requires registration on or before `Activity.onCreate`.
    /// - Returns: the `ActivityResult`, or `nil` if no launcher is registered.
    public func startActivityForResult(_ intent: Intent) async -> ActivityResult? {
        guard let startActivityLauncher else {
            logger.warning("startActivityForResult: startActivityLauncher is nil")
            return nil
        }
        return suspendCoroutine { continuation in
            var count = 0
            synchronized(activityResultContinuations) {
                activityResultContinuations.add(continuation)
                count = activityResultContinuations.count()
            }
            if count == 1 {
                startActivityLauncher?.launch(intent)
            }
        }
    }

    private func resultURIString(_ result: ActivityResult?) -> String? {
        guard let result, result.resultCode == Activity.RESULT_OK else { return nil }
        return result.data?.data?.toString()
    }

    /// Ask the owner to pick a single photo or video, returning its content URI.
    /// - Parameter mimeType: `"image/*"`, `"video/*"`, or empty to offer both.
    // SKIP @bridge
    public func pickMediaURI(_ mimeType: String) async -> String? {
        let intent: Intent
        if Build.VERSION.SDK_INT >= 33 {
            // The system photo picker. It offers photos and videos together when no type is set;
            // ACTION_PICK_IMAGES rejects a wildcard type, so an empty request leaves it unset.
            intent = Intent(MediaStore.ACTION_PICK_IMAGES)
            if !mimeType.isEmpty {
                intent.type = mimeType
            }
        } else {
            intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            intent.type = mimeType.isEmpty ? "*/*" : mimeType
        }
        return resultURIString(await startActivityForResult(intent))
    }

    /// The MIME type of the document at the given content URI.
    // SKIP @bridge
    public func contentURIType(_ uriString: String) -> String? {
        do {
            return ProcessInfo.processInfo.androidContext.contentResolver.getType(android.net.Uri.parse(uriString))
        } catch {
            logger.warning("contentURIType: \(error)")
            return nil
        }
    }

    /// Ask the owner where to write a new document, returning its content URI.
    // SKIP @bridge
    public func createDocumentURI(_ name: String, mimeType: String) async -> String? {
        let intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        intent.putExtra(Intent.EXTRA_TITLE, name)
        return resultURIString(await startActivityForResult(intent))
    }

    /// Ask the owner to pick an existing document, returning its content URI.
    // SKIP @bridge
    public func openDocumentURI(_ mimeType: String) async -> String? {
        let intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        return resultURIString(await startActivityForResult(intent))
    }

    /// Ask the owner to pick a folder, returning its tree URI with persisted read and write access.
    // SKIP @bridge
    public func openDocumentTreeURI() async -> String? {
        let intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        guard let uriString = resultURIString(await startActivityForResult(intent)) else { return nil }
        do {
            let context = ProcessInfo.processInfo.androidContext
            context.contentResolver.takePersistableUriPermission(android.net.Uri.parse(uriString), Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch {
            logger.warning("openDocumentTreeURI: could not persist permission: \(error)")
        }
        return uriString
    }

    /// The MIME type that asks `createChildDocument` for a folder rather than a file.
    // SKIP @bridge
    public static let documentFolderMIMEType = "vnd.android.document/directory" // DocumentsContract.Document.MIME_TYPE_DIR

    /// The document URI of a chosen folder's own root, which is what the child calls below take as a parent.
    ///
    /// A tree URI and a document URI are not interchangeable: the tree URI names the grant, the document URI
    /// names a node inside it. Everything below therefore works in document URIs, so a subfolder is as good
    /// a parent as the folder the owner picked.
    // SKIP @bridge
    public func documentTreeRootURI(_ treeURIString: String) -> String? {
        do {
            let treeURI = android.net.Uri.parse(treeURIString)
            return DocumentsContract.buildDocumentUriUsingTree(treeURI, DocumentsContract.getTreeDocumentId(treeURI)).toString()
        } catch {
            logger.warning("documentTreeRootURI: \(error)")
            return nil
        }
    }

    /// Create a document, or with `documentFolderMIMEType` a folder, inside the given folder.
    // SKIP @bridge
    public func createChildDocument(_ parentURIString: String, name: String, mimeType: String) -> String? {
        do {
            let context = ProcessInfo.processInfo.androidContext
            let parent = android.net.Uri.parse(parentURIString)
            return DocumentsContract.createDocument(context.contentResolver, parent, mimeType, name)?.toString()
        } catch {
            logger.warning("createChildDocument: \(error)")
            return nil
        }
    }

    private func childDocumentsURI(_ parentURIString: String) -> android.net.Uri {
        let parent = android.net.Uri.parse(parentURIString)
        return DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
    }

    /// The names of the documents directly inside the given folder.
    ///
    /// Returned newline separated, since arrays of Foundation values are not safe across the bridge.
    // SKIP @bridge
    public func childDocumentNames(_ parentURIString: String) -> String {
        do {
            let context = ProcessInfo.processInfo.androidContext
            // A `nil` projection asks for every column: Skip maps `arrayOf` to its own Array type, which
            // the ContentResolver signature will not take, so the columns are read back by name instead.
            guard let cursor = context.contentResolver.query(childDocumentsURI(parentURIString), nil, nil, nil, nil) else { return "" }
            let nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            var names: [String] = []
            while cursor.moveToNext() {
                names.append(cursor.getString(nameColumn))
            }
            cursor.close()
            return names.joined(separator: "\n")
        } catch {
            logger.warning("childDocumentNames: \(error)")
            return ""
        }
    }

    /// The document URI of a named document directly inside the given folder, if it exists.
    // SKIP @bridge
    public func childDocumentURI(_ parentURIString: String, name: String) -> String? {
        do {
            let context = ProcessInfo.processInfo.androidContext
            let parent = android.net.Uri.parse(parentURIString)
            guard let cursor = context.contentResolver.query(childDocumentsURI(parentURIString), nil, nil, nil, nil) else { return nil }
            let idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            let nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            var found: String? = nil
            while cursor.moveToNext() {
                if cursor.getString(nameColumn) == name {
                    found = DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(idColumn)).toString()
                    break
                }
            }
            cursor.close()
            return found
        } catch {
            logger.warning("childDocumentURI: \(error)")
            return nil
        }
    }

    /// The display name of the document at the given content URI.
    // SKIP @bridge
    public func contentURIName(_ uriString: String) -> String? {
        do {
            let context = ProcessInfo.processInfo.androidContext
            guard let cursor = context.contentResolver.query(android.net.Uri.parse(uriString), nil, nil, nil, nil) else { return nil }
            var name: String? = nil
            if cursor.moveToFirst() {
                name = cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
            }
            cursor.close()
            return name
        } catch {
            logger.warning("contentURIName: \(error)")
            return nil
        }
    }

    /// The bytes of the document at the given content URI.
    // SKIP @bridge
    public func readContentURI(_ uriString: String) -> Data? {
        do {
            let context = ProcessInfo.processInfo.androidContext
            guard let stream = context.contentResolver.openInputStream(android.net.Uri.parse(uriString)) else { return nil }
            let bytes = stream.readBytes()
            stream.close()
            return Data(platformValue: bytes)
        } catch {
            logger.warning("readContentURI: \(error)")
            return nil
        }
    }

    /// Write bytes to the document at the given content URI, replacing whatever was there.
    // SKIP @bridge
    public func writeContentURI(_ uriString: String, data: Data) -> Bool {
        do {
            let context = ProcessInfo.processInfo.androidContext
            // "wt" truncates; plain "w" leaves a shorter write with the tail of the old contents
            guard let stream = context.contentResolver.openOutputStream(android.net.Uri.parse(uriString), "wt") else { return false }
            stream.write(data.platformValue)
            stream.flush()
            stream.close()
            return true
        } catch {
            logger.warning("writeContentURI: \(error)")
            return false
        }
    }

    /// Hand the document at the given content URI to whichever app can display it.
    // SKIP @bridge
    public func openContentURI(_ uriString: String, mimeType: String) -> Bool {
        do {
            let intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(android.net.Uri.parse(uriString), mimeType)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if let androidActivity {
                androidActivity.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ProcessInfo.processInfo.androidContext.startActivity(intent)
            }
            return true
        } catch {
            logger.warning("openContentURI: \(error)")
            return false
        }
    }

    private var allowedAuthenticators: Int {
        if Build.VERSION.SDK_INT >= 30 {
            return BiometricManager.Authenticators.BIOMETRIC_WEAK | BiometricManager.Authenticators.DEVICE_CREDENTIAL
        } else {
            return BiometricManager.Authenticators.DEVICE_CREDENTIAL
        }
    }

    /// Whether this device can ask its owner for a fingerprint, a face or a screen-lock credential.
    // SKIP @bridge
    public func canAuthenticateDeviceOwner() -> Bool {
        do {
            let context = ProcessInfo.processInfo.androidContext
            return BiometricManager.from(context).canAuthenticate(allowedAuthenticators) == BiometricManager.BIOMETRIC_SUCCESS
        } catch {
            logger.warning("canAuthenticateDeviceOwner: \(error)")
            return false
        }
    }

    /// Ask the owner for a fingerprint, a face or the screen-lock credential.
    /// - Returns: true only if the prompt succeeded.
    // SKIP @bridge
    public func authenticateDeviceOwner(title: String, subtitle: String) async -> Bool {
        guard let activity = self.androidActivity as? FragmentActivity else {
            logger.warning("authenticateDeviceOwner: no FragmentActivity")
            return false
        }
        return suspendCoroutine { continuation in
            let callback = BiometricAuthenticationCallback(continuation: continuation)
            activity.runOnUiThread {
                do {
                    let executor = ContextCompat.getMainExecutor(activity)
                    let prompt = BiometricPrompt(activity, executor, callback)
                    let info = BiometricPrompt.PromptInfo.Builder()
                        .setTitle(title)
                        .setSubtitle(subtitle)
                        .setAllowedAuthenticators(allowedAuthenticators)
                        .build()
                    prompt.authenticate(info)
                } catch {
                    logger.warning("authenticateDeviceOwner: \(error)")
                    callback.resumeOnce(false)
                }
            }
        }
    }

    /// Requests the given permission.
    /// - Parameters:
    ///   - permission: the name of the permission, such as `android.permission.POST_NOTIFICATIONS`
    ///   - showRationale: an optional async callback to invoke when the system determies that a rationale should be displayed for the permission check
    /// - Returns: true if the permission was granted, false if denied or there was an error making the request
    public func requestPermission(_ permission: String, showRationale: (() async -> Bool)?) async -> Bool {
        logger.info("requestPermission: \(permission)")
        guard let activity = self.androidActivity else {
            return false
        }
        if ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED {
            return true // already granted
        }
        guard let requestPermissionLauncher else {
            logger.warning("requestPermission: \(permission) requestPermissionLauncher is nil")
            return false
        }
        // check if we are expected to show a rationalle for the permission request, and if so,
        // and if we have a `showRationale` callback, then wait for the result
        if let showRationale, ActivityCompat.shouldShowRequestPermissionRationale(activity, permission) == true {
            if await showRationale() == false {
                return false
            }
        }
        suspendCoroutine { continuation in
            var count = 0
            synchronized(waitingContinuations) {
                waitingContinuations.add(continuation)
                count = waitingContinuations.count()
            }
            if count == 1 {
                logger.info("launch requestPermission: \(permission)")
                requestPermissionLauncher?.launch(permission)
            }
        }
    }

    /// Requests the given permission.
    /// - Parameters:
    ///   - permission: the name of the permission, such as `android.permission.POST_NOTIFICATIONS`
    /// - Returns: true if the permission was granted, false if denied or there was an error making the request
    // SKIP @bridge
    public func requestPermission(_ permission: String) async -> Bool {
        // We can't bridge the `showRationale` parameter async closure
        return await requestPermission(permission, showRationale: nil)
    }
    #endif

    @available(*, unavailable)
    public var delegate: Any? {
        get {
            fatalError()
        }
        set {
        }
    }

    // SKIP @bridge
    public var isIdleTimerDisabled = false {
        didSet {
            setWindowFlagsForIsIdleTimerDisabled()
        }
    }

    private func setWindowFlagsForIsIdleTimerDisabled() {
        #if SKIP
        let flags = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        if isIdleTimerDisabled {
            androidActivity?.window?.addFlags(flags)
        } else {
            androidActivity?.window?.clearFlags(flags)
        }
        #endif
    }

    @available(*, unavailable)
    public func canOpenURL(_ url: URL) -> Bool {
        fatalError()
    }

    #if SKIP
    public static let openSettingsURLString = "intent://" + Settings.ACTION_APPLICATION_DETAILS_SETTINGS
    public static let openDefaultApplicationsSettingsURLString = "intent://android.settings.APP_OPEN_BY_DEFAULT_SETTINGS" // ACTION_APP_OPEN_BY_DEFAULT_SETTINGS added in API 31
    public static let openNotificationSettingsURLString = "intent://" + Settings.ACTION_APP_NOTIFICATION_SETTINGS
    #endif

    public func open(_ url: URL, options: [OpenExternalURLOptionsKey : Any] = [:]) async -> Bool {
        #if SKIP
        let context = ProcessInfo.processInfo.androidContext
        do {
            let intent: Intent
            let uri = android.net.Uri.parse(url.absoluteString)
            // adding the Android-specific URL key "intent" will use the custom intent name
            if let intentName = options[OpenExternalURLOptionsKey.intent] as? String {
                intent = Intent(intentName, uri)
            } else if url.scheme == "intent" {
                let action = url.host()
                // ACTION_APP_NOTIFICATION_SETTINGS requires the package name as an extra, not in the data URI
                if action == Settings.ACTION_APP_NOTIFICATION_SETTINGS {
                    intent = Intent(action)
                    intent.putExtra(Settings.EXTRA_APP_PACKAGE, context.getPackageName())
                } else {
                    intent = Intent(action, android.net.Uri.parse("package:" + context.getPackageName()))
                }
            } else if url.scheme == "tel" {
                intent = Intent(Intent.ACTION_DIAL, uri)
            } else if url.scheme == "sms" || url.scheme == "mailto" {
                intent = Intent(Intent.ACTION_SENDTO, uri)
            } else {
                intent = Intent(Intent.ACTION_VIEW, uri)
            }
            for (key, value) in options {
                if key.rawValue == OpenExternalURLOptionsKey.intent.rawValue { continue }
                if let valueString = value as? String {
                    intent.putExtra(key.rawValue, valueString)
                }
            }
            if let androidActivity {
                androidActivity.startActivity(intent)
            } else {
                // needed or else: android.util.AndroidRuntimeException: Calling startActivity() from outside of an Activity context requires the FLAG_ACTIVITY_NEW_TASK flag. Is this really what you want?
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
            return true
        } catch {
            logger.warning("UIApplication.launch error: \(error)")
            return false
        }
        #else
        fatalError()
        #endif
    }

    // SKIP @bridge
    public func bridgedOpen(_ url: URL, options: [String : Any]) async -> Bool {
        let keyedOptions = options.reduce(into: [OpenExternalURLOptionsKey : Any]()) { result, entry in
            result[OpenExternalURLOptionsKey(rawValue: entry.key)] = entry.value
        }
        return await open(url, options: keyedOptions)
    }

    @available(*, unavailable)
    public func sendEvent(_ event: Any) {
    }
    @available(*, unavailable)
    public func sendAction(_ action: Any /* Selector */, to target: Any?, from sender: Any?, for event: Any?) -> Bool {
        fatalError()
    }
    @available(*, unavailable)
    public func supportedInterfaceOrientations(for window: Any?) -> Any /* UIInterfaceOrientationMask */ {
        fatalError()
    }
    @available(*, unavailable)
    public var applicationSupportsShakeToEdit: Bool {
        get {
            fatalError()
        }
        set {
        }
    }

    #if SKIP
    public internal(set) var applicationState: UIApplication.State {
        get {
            return _applicationState.value
        }
        set {
            _applicationState.value = newValue
        }
    }
    private let _applicationState: MutableState<UIApplication.State> = mutableStateOf(UIApplication.State.active)
    #else
    private let applicationState = UIApplication.State.active
    #endif

    // SKIP @bridge
    public var bridgedApplicationState: Int {
        return applicationState.rawValue
    }

    @available(*, unavailable)
    public var backgroundTimeRemaining: TimeInterval {
        fatalError()
    }
    @available(*, unavailable)
    public func beginBackgroundTask(expirationHandler handler: (() -> Void)? = nil) -> Any /* UIBackgroundTaskIdentifier */ {
        fatalError()
    }
    @available(*, unavailable)
    public func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (() -> Void)? = nil) -> Any /* UIBackgroundTaskIdentifier */ {
        fatalError()
    }
    @available(*, unavailable)
    public func endBackgroundTask(_ identifier: Any /* UIBackgroundTaskIdentifier */) {
    }
    @available(*, unavailable)
    public var backgroundRefreshStatus: Any /* UIBackgroundRefreshStatus */ {
        fatalError()
    }
    @available(*, unavailable)
    public var isProtectedDataAvailable: Bool {
        fatalError()
    }
    @available(*, unavailable)
    public var userInterfaceLayoutDirection: Any /* UIUserInterfaceLayoutDirection */ {
        fatalError()
    }
    @available(*, unavailable)
    public var preferredContentSizeCategory: Any /* UIContentSizeCategory */ {
        fatalError()
    }
    @available(*, unavailable)
    public var connectedScenes: Set<AnyHashable /* UIScene */> {
        fatalError()
    }
    @available(*, unavailable)
    public var openSessions: Set<AnyHashable /* UISceneSession */> {
        fatalError()
    }
    @available(*, unavailable)
    public var supportsMultipleScenes: Bool {
        fatalError()
    }
    @available(*, unavailable)
    public func requestSceneSessionDestruction(_ sceneSession: Any /* UISceneSession */, options: Any? /* UISceneDestructionRequestOptions? */, errorHandler: ((Error) -> Void)? = nil) {
    }
    @available(*, unavailable)
    public func requestSceneSessionRefresh(_ sceneSession: Any /* UISceneSession */) {
    }
    @available(*, unavailable)
    public func activateSceneSession(for request: Any /* UISceneSessionActivationRequest */, errorHandler: ((Error) -> Void)? = nil) {
    }
    @available(*, unavailable)
    public func registerForRemoteNotifications() {
    }
    @available(*, unavailable)
    public func unregisterForRemoteNotifications() {
    }
    @available(*, unavailable)
    public var isRegisteredForRemoteNotifications: Bool {
        fatalError()
    }
    @available(*, unavailable)
    public func beginReceivingRemoteControlEvents() {
    }
    @available(*, unavailable)
    public func endReceivingRemoteControlEvents() {
    }
    @available(*, unavailable)
    public var shortcutItems: Any? /* [UIApplicationShortcutItem]? */ {
        fatalError()
    }
    @available(*, unavailable)
    public var supportsAlternateIcons: Bool {
        fatalError()
    }
    @available(*, unavailable)
    public func setAlternateIconName(_ alternateIconName: String?, completionHandler: ((Error?) -> Void)? = nil) {
    }
    @available(*, unavailable)
    public func setAlternateIconName(_ alternateIconName: String?) async throws {
    }
    @available(*, unavailable)
    public var alternateIconName: String? {
        fatalError()
    }
    @available(*, unavailable)
    public func extendStateRestoration() {
    }
    @available(*, unavailable)
    public func completeStateRestoration() {
    }
    @available(*, unavailable)
    public func ignoreSnapshotOnNextApplicationLaunch() {
    }
    @available(*, unavailable)
    public static func registerObject(forStateRestoration object: Any /* UIStateRestoring */, restorationIdentifier: String) {
    }
    @available(*, unavailable)
    public static var didEnterBackgroundNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var willEnterForegroundNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var didFinishLaunchingNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var didBecomeActiveNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var willResignActiveNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var didReceiveMemoryWarningNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var willTerminateNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var significantTimeChangeNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var backgroundRefreshStatusDidChangeNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var protectedDataWillBecomeUnavailableNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var protectedDataDidBecomeAvailableNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var userDidTakeScreenshotNotification: Notification.Name {
        fatalError()
    }
    @available(*, unavailable)
    public static var invalidInterfaceOrientationException: Any {
        fatalError()
    }

    // NOTE: Keep in sync with SkipSwiftUI.UIApplication.State
    public enum State : Int {
        case active = 0
        case inactive = 1
        case background = 2
    }

    @available(*, unavailable)
    public static var backgroundFetchIntervalMinimum: TimeInterval {
        fatalError()
    }
    @available(*, unavailable)
    public static var backgroundFetchIntervalNever: TimeInterval {
        fatalError()
    }

    public struct OpenExternalURLOptionsKey : Hashable, Equatable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public static let universalLinksOnly = OpenExternalURLOptionsKey(rawValue: "universalLinksOnly")
        public static let eventAttribution = OpenExternalURLOptionsKey(rawValue: "eventAttribution")

        // Android-specific keys
        public static let intent = OpenExternalURLOptionsKey(rawValue: "intent")
    }
}

#if SKIP
/// Bridges `BiometricPrompt`'s callback back to the suspended Swift caller.
///
/// `onAuthenticationFailed` deliberately does not resume: it fires per rejected fingerprint while the
/// prompt is still up, and resuming there would report a failure the owner is still in the middle of
/// correcting. Only success and a terminal error end the wait.
class BiometricAuthenticationCallback: BiometricPrompt.AuthenticationCallback {
    private let continuation: Continuation<Bool>
    private var resumed = false

    init(continuation: Continuation<Bool>) {
        self.continuation = continuation
    }

    func resumeOnce(_ value: Bool) {
        var shouldResume = false
        synchronized(self) {
            if !resumed {
                resumed = true
                shouldResume = true
            }
        }
        if shouldResume {
            continuation.resume(value)
        }
    }

    override func onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
        resumeOnce(true)
    }

    override func onAuthenticationError(errorCode: Int, errString: CharSequence) {
        resumeOnce(false)
    }
}

struct UIApplicationLifecycleEventObserver: LifecycleEventObserver, DefaultLifecycleObserver {
    let application: UIApplication

    override func onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
        switch event {
        case Lifecycle.Event.ON_CREATE:
            break
        case Lifecycle.Event.ON_START:
            break
        case Lifecycle.Event.ON_RESUME:
            application.applicationState = .active
        case Lifecycle.Event.ON_PAUSE:
            application.applicationState = .inactive
        case Lifecycle.Event.ON_STOP:
            application.applicationState = .background
        case Lifecycle.Event.ON_DESTROY:
            application.onActivityDestroy()
        case Lifecycle.Event.ON_ANY:
            break
        }
    }
}
#endif
#endif
