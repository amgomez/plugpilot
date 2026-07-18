import Cocoa
import CShim
import ServiceManagement
import CoreWLAN
import SystemConfiguration
import XPC

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var runLoopSource: CFRunLoopSource?
    private var dynamicStore: SCDynamicStore?
    private var lastOnACPower = true
    private var lastEthernetActive = false

    // Número de ventiladores de esta máquina, detectado en el arranque vía SMC (FNum):
    // no hay tabla fija, cada Mac tiene su propio hardware. En muchos firmwares Intel el
    // mínimo (F#Mn) es de solo lectura: el modo agresivo fuerza F#Md=1 con F#Tg a un
    // objetivo calculado a partir de F#Mn/F#Mx en el momento de aplicar la política, y
    // restaurar es simplemente devolver el modo a auto (F#Md=0).
    private var fanCount = 0
    private static let fanIntensityOptions = [25, 33, 50, 75]

    // Capacidades de esta máquina, detectadas una sola vez en el arranque (no cambian en
    // caliente) para ocultar del menú lo que no aplique: MacBook Air sin ventiladores,
    // sobremesa sin batería, Mac sin Wi-Fi, sensores de temperatura sin claves legibles.
    private var hasFans = false
    private var hasBattery = false
    private var hasWiFi = false
    private var hasCPUTemperature = false
    private var hasBatteryTemperature = false

    // Las escrituras al SMC requieren root (kIOReturnNotPrivileged desde usuario), así
    // que las hace un daemon bajo demanda registrado con SMAppService y hablado por XPC.
    private static let helperPlistName = "com.amgg.plugpilot.helper.plist"
    private static let helperServiceName = "com.amgg.plugpilot.helper"
    private var helperConnection: xpc_connection_t?
    private var pendingFanVerification = 0
    // Solo hay que restaurar los mínimos de fábrica si llegamos a aplicar los agresivos:
    // evita lanzar el helper root cuando la función no se usa.
    private var appliedAggressiveFans = false

    private static let aggressiveFansDefaultsKey = "aggressiveFansOnAC"
    private var aggressiveFansEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.aggressiveFansDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.aggressiveFansDefaultsKey) }
    }

    private static let bluetoothPolicyDefaultsKey = "bluetoothPolicyEnabled"
    private var bluetoothPolicyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.bluetoothPolicyDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bluetoothPolicyDefaultsKey) }
    }

    private static let wifiPolicyDefaultsKey = "wifiPolicyEnabled"
    private var wifiPolicyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.wifiPolicyDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.wifiPolicyDefaultsKey) }
    }

    private static let fanIntensityDefaultsKey = "fanIntensityPercent"
    private var fanIntensityPercent: Int {
        get { UserDefaults.standard.integer(forKey: Self.fanIntensityDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.fanIntensityDefaultsKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Los defaults de un usuario nuevo: las tres políticas apagadas (una app que
        // apaga radios sin avisar espanta) e intensidad media. El dominio de UserDefaults
        // es propio del bundle id, así que no hay migración desde versiones anteriores.
        UserDefaults.standard.register(defaults: [
            Self.bluetoothPolicyDefaultsKey: false,
            Self.wifiPolicyDefaultsKey: false,
            Self.aggressiveFansDefaultsKey: false,
            Self.fanIntensityDefaultsKey: 33
        ])

        // Las claves SMC de una máquina no cambian en caliente: basta con leer FNum una
        // vez en el arranque.
        fanCount = Int(SMCGetFanCount())
        hasFans = fanCount > 0
        hasBattery = detectHasBattery()
        hasWiFi = CWWiFiClient.shared().interface() != nil
        hasCPUTemperature = readTemperature(candidateKeys: Self.cpuTemperatureKeys) != nil
        hasBatteryTemperature = hasBattery && readTemperature(candidateKeys: Self.batteryTemperatureKeys) != nil

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "PlugPilot")

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: NSLocalizedString("status.checking", comment: "Estado inicial antes de la primera lectura"), action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        let bluetoothMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bluetoothMenuItem.tag = 106
        bluetoothMenuItem.indentationLevel = 1
        // Logo real de Bluetooth que trae el sistema (imagen plantilla: se tiñe sola).
        if let logo = NSImage(named: NSImage.bluetoothTemplateName)?.copy() as? NSImage {
            logo.size = NSSize(width: 16, height: 16)
            bluetoothMenuItem.image = logo
        }
        menu.addItem(bluetoothMenuItem)

        let networkMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        networkMenuItem.tag = 101
        networkMenuItem.indentationLevel = 1
        networkMenuItem.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "Wi-Fi")
        networkMenuItem.isHidden = !hasWiFi
        menu.addItem(networkMenuItem)

        let temperatureMenuItem = NSMenuItem(title: NSLocalizedString("cpu.temperature.placeholder", comment: "Placeholder inicial de temperatura de CPU"), action: nil, keyEquivalent: "")
        temperatureMenuItem.tag = 102
        temperatureMenuItem.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")
        temperatureMenuItem.isHidden = !hasCPUTemperature
        menu.addItem(temperatureMenuItem)

        let batteryTempMenuItem = NSMenuItem(title: NSLocalizedString("battery.temperature.placeholder", comment: "Placeholder inicial de temperatura de batería"), action: nil, keyEquivalent: "")
        batteryTempMenuItem.tag = 103
        batteryTempMenuItem.image = NSImage(systemSymbolName: "battery.100percent", accessibilityDescription: NSLocalizedString("accessibility.battery", comment: "Descripción de accesibilidad del icono de batería"))
        batteryTempMenuItem.isHidden = !hasBatteryTemperature
        menu.addItem(batteryTempMenuItem)

        let fanMenuItem = NSMenuItem(title: NSLocalizedString("fans.placeholder", comment: "Placeholder inicial de ventiladores"), action: nil, keyEquivalent: "")
        fanMenuItem.tag = 104
        fanMenuItem.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: NSLocalizedString("accessibility.fans", comment: "Descripción de accesibilidad del icono de ventiladores"))
        fanMenuItem.isHidden = !hasFans
        menu.addItem(fanMenuItem)
        menu.addItem(.separator())

        let bluetoothPolicyItem = NSMenuItem(title: NSLocalizedString("menu.bluetoothPolicy", comment: "Checkbox: Bluetooth solo con cargador"), action: #selector(toggleBluetoothPolicy(_:)), keyEquivalent: "")
        bluetoothPolicyItem.tag = 107
        bluetoothPolicyItem.target = self
        bluetoothPolicyItem.state = bluetoothPolicyEnabled ? .on : .off
        // Sin batería siempre hay corriente: la política "solo con cargador" no haría
        // nunca nada.
        bluetoothPolicyItem.isHidden = !hasBattery
        menu.addItem(bluetoothPolicyItem)

        let wifiPolicyItem = NSMenuItem(title: NSLocalizedString("menu.wifiPolicy", comment: "Checkbox: Wi-Fi solo sin Ethernet"), action: #selector(toggleWiFiPolicy(_:)), keyEquivalent: "")
        wifiPolicyItem.tag = 108
        wifiPolicyItem.target = self
        wifiPolicyItem.state = wifiPolicyEnabled ? .on : .off
        wifiPolicyItem.isHidden = !hasWiFi
        menu.addItem(wifiPolicyItem)

        // Un único submenú en vez de checkbox + submenú separados: "activar" y "elegir
        // intensidad" son la misma decisión, así que "por defecto" (auto SMC) es una
        // opción más de la lista en lugar de un caso aparte.
        let fanIntensityMenu = NSMenu()
        let fanOffItem = NSMenuItem(title: NSLocalizedString("fanIntensity.off", comment: "Intensidad de ventiladores: por defecto (control automático del SMC)"), action: #selector(selectFanIntensity(_:)), keyEquivalent: "")
        fanOffItem.tag = 0
        fanOffItem.target = self
        fanOffItem.state = aggressiveFansEnabled ? .off : .on
        fanIntensityMenu.addItem(fanOffItem)
        for percent in Self.fanIntensityOptions {
            let item = NSMenuItem(title: fanIntensityTitle(for: percent), action: #selector(selectFanIntensity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = (aggressiveFansEnabled && fanIntensityPercent == percent) ? .on : .off
            fanIntensityMenu.addItem(item)
        }
        let aggressiveFansItem = NSMenuItem(title: NSLocalizedString("fans.aggressive.title", comment: "Submenú: intensidad de ventiladores, solo con cargador"), action: nil, keyEquivalent: "")
        aggressiveFansItem.tag = 105
        aggressiveFansItem.submenu = fanIntensityMenu
        aggressiveFansItem.isHidden = !hasFans
        menu.addItem(aggressiveFansItem)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: NSLocalizedString("menu.loginItem", comment: "Checkbox: abrir automáticamente al iniciar sesión"), action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: NSLocalizedString("menu.quit", comment: "Salir de la app"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu

        // Las suscripciones se registran ANTES de leer el estado inicial: una transición
        // que ocurra entre la lectura y el registro se perdería para siempre.
        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            let me = Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue()
            me.powerSourceChanged()
        }, context)?.takeRetainedValue()

        if let source = runLoopSource {
            // .commonModes: con .defaultMode la notificación no se entrega mientras un
            // menú está abierto (el run loop pasa a modo de event tracking).
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        startEthernetLinkMonitoring()

        // Los mínimos de RPM del SMC vuelven a su valor de fábrica tras dormir, así que hay
        // que reaplicar la política de ventiladores cada vez que el equipo despierta.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Válvula térmica: si el sistema sale del estado 'nominal' se devuelve el control
        // de ventiladores al SMC (que puede subirlos a tope), y al volver a nominal se
        // re-fuerzan las RPM agresivas. Notificación por suscripción, sin polling.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )

        // Si la preferencia quedó activada en una sesión anterior, reintenta el registro
        // del helper (sin abrir Ajustes: el aviso ya se muestra en el propio menú) y
        // comprueba que el daemon de verdad arranca, reparándolo si no.
        if hasFans && aggressiveFansEnabled {
            ensureHelperRegistered(openSettings: false)
            verifyHelperAndRepairIfNeeded()
        }

        lastOnACPower = isOnACPower()
        applyPowerState(onAC: lastOnACPower)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Síncrono: un mensaje XPC asíncrono podría no llegar a enviarse antes de morir.
        applyFanPolicy(onAC: false, synchronous: true)
    }

    @objc private func systemDidWake() {
        applyFanPolicy(onAC: isOnACPower())
        // Si la alimentación cambió durante el sueño, esto aplica la transición ya.
        // No se escribe lastOnACPower directamente: powerSourceChanged compara y
        // deduplica, así que da igual si la notificación de IOPS llega antes o
        // después de esta llamada (la segunda será un no-op).
        powerSourceChanged()
        // El enlace Ethernet también puede haber cambiado durante el sueño.
        evaluateWiFiPolicy(forceApply: false)
    }

    private func isOnACPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let typeRef = IOPSGetProvidingPowerSourceType(snapshot) else { return false }
        let type = typeRef.takeUnretainedValue() as String
        return type == (kIOPSACPowerValue as String)
    }

    // Sobremesa (sin batería) vs. portátil: lista de fuentes de energía vacía.
    private func detectHasBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        return !sources.isEmpty
    }

    private func powerSourceChanged() {
        let onAC = isOnACPower()
        guard onAC != lastOnACPower else { return }
        lastOnACPower = onAC
        applyPowerState(onAC: onAC)
    }

    private func applyPowerState(onAC: Bool) {
        if bluetoothPolicyEnabled {
            IOBluetoothPreferenceSetControllerPowerState(onAC ? 1 : 0)
        }
        applyFanPolicy(onAC: onAC)
        evaluateWiFiPolicy(forceApply: true)
    }

    // Suscripción a los cambios de enlace de las interfaces de red vía configd.
    // Sustituye al antiguo chequeo único con retardo fijo de 2 s: un dock puede tardar
    // más en levantar la interfaz Ethernet, y aquí configd nos avisa justo cuando el
    // enlace sube o baja, sin consumir nada mientras tanto.
    private func startEthernetLinkMonitoring() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(nil, "PlugPilot" as CFString, { _, _, info in
            guard let info else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            me.evaluateWiFiPolicy(forceApply: false)
        }, &context),
              SCDynamicStoreSetNotificationKeys(store, nil, ["State:/Network/Interface/.*/Link" as CFString] as CFArray),
              SCDynamicStoreSetDispatchQueue(store, .main) else {
            NSLog("No se pudo suscribir a los cambios de enlace de red")
            return
        }
        dynamicStore = store
    }

    /// Aplica la política de Wi-Fi: apagada cuando hay enlace Ethernet real, sin importar
    /// la alimentación (la dependencia del cargador era un resto de versiones anteriores
    /// a la suscripción a cambios de enlace, cuando aún no se distinguía un evento real).
    /// En eventos de enlace (`forceApply: false`) solo se actúa si el estado del enlace
    /// cambió de verdad, para no pisar un ajuste manual del usuario; en transiciones de
    /// alimentación se aplica siempre.
    private func evaluateWiFiPolicy(forceApply: Bool) {
        let ethernet = isEthernetConnected()
        let linkChanged = ethernet != lastEthernetActive
        // Se actualiza siempre, aunque la política esté desactivada: el estado del
        // enlace se muestra en el menú y no debe quedar a medias.
        lastEthernetActive = ethernet

        if wifiPolicyEnabled && (forceApply || linkChanged) {
            setWiFiPower(!ethernet)
        }
        updateStatusMenu()
    }

    @objc private func toggleBluetoothPolicy(_ sender: NSMenuItem) {
        bluetoothPolicyEnabled.toggle()
        sender.state = bluetoothPolicyEnabled ? .on : .off
        // Al activar se aplica de inmediato con el estado actual; al desactivar no se
        // restaura nada, el usuario manda a partir de ahora.
        if bluetoothPolicyEnabled {
            IOBluetoothPreferenceSetControllerPowerState(lastOnACPower ? 1 : 0)
        }
    }

    @objc private func toggleWiFiPolicy(_ sender: NSMenuItem) {
        wifiPolicyEnabled.toggle()
        sender.state = wifiPolicyEnabled ? .on : .off
        if wifiPolicyEnabled {
            setWiFiPower(!lastEthernetActive)
        }
    }

    private func fanIntensityTitle(for percent: Int) -> String {
        switch percent {
        case 25: return NSLocalizedString("fanIntensity.soft", comment: "Intensidad de ventiladores: 25%")
        case 33: return NSLocalizedString("fanIntensity.medium", comment: "Intensidad de ventiladores: 33%")
        case 50: return NSLocalizedString("fanIntensity.strong", comment: "Intensidad de ventiladores: 50%")
        case 75: return NSLocalizedString("fanIntensity.extreme", comment: "Intensidad de ventiladores: 75%")
        default: return "\(percent) %"
        }
    }

    @objc private func selectFanIntensity(_ sender: NSMenuItem) {
        let percent = sender.tag
        if percent == 0 {
            aggressiveFansEnabled = false
        } else {
            let wasEnabled = aggressiveFansEnabled
            aggressiveFansEnabled = true
            fanIntensityPercent = percent
            // Registro del helper solo en la transición de apagado a encendido, igual
            // que antes hacía el checkbox: cambiar de intensidad ya activo no lo repite.
            if !wasEnabled {
                ensureHelperRegistered(openSettings: true)
            }
        }
        applyFanPolicy(onAC: lastOnACPower)
        updateAggressiveFansMenuItem()
    }

    @objc private func thermalStateChanged() {
        // La notificación puede llegar en cualquier hilo; todo el estado vive en main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyFanPolicy(onAC: self.lastOnACPower)
        }
    }

    private func applyFanPolicy(onAC: Bool, synchronous: Bool = false, isRetry: Bool = false) {
        // Solo se fuerzan RPM con el sistema térmicamente 'nominal': en cuanto sube el
        // estado térmico, el control vuelve al SMC para que ventile lo que haga falta.
        let wantAggressive = onAC && aggressiveFansEnabled && ProcessInfo.processInfo.thermalState == .nominal
        // Sin nada que cambiar no se lanza el helper: el modo forzado vuelve solo a auto
        // tras dormir, y si nunca lo aplicamos no hay nada que restaurar.
        if wantAggressive || appliedAggressiveFans {
            if wantAggressive {
                for index in 0..<fanCount {
                    guard let rpm = aggressiveTargetRPM(forFan: index) else { continue }
                    sendFanCommand(fanIndex: index, forced: true, rpm: rpm, synchronous: synchronous)
                }
            } else {
                for index in 0..<fanCount {
                    sendFanCommand(fanIndex: index, forced: false, rpm: 0, synchronous: synchronous)
                }
            }
            appliedAggressiveFans = wantAggressive
        }
        guard !synchronous, !isRetry else { return }
        scheduleFanPolicyVerification()
    }

    // Objetivo agresivo del ventilador `index`, leído en el momento de aplicar la
    // política (F#Mn/F#Mx son legibles sin privilegios y no cambian en caliente, pero
    // recalcular aquí evita mantener una tabla propia). nil si el SMC no responde.
    private func aggressiveTargetRPM(forFan index: Int) -> Double? {
        let minimum = "F\(index)Mn".withCString { SMCGetFloatValue($0) }
        let maximum = "F\(index)Mx".withCString { SMCGetFloatValue($0) }
        guard minimum >= 0, maximum >= 0 else { return nil }
        return max(minimum, (Double(fanIntensityPercent) / 100.0) * maximum)
    }

    // Verificación única tras cada aplicación de política (no es polling: solo se
    // programa como reacción a un evento). Los envíos al helper son asíncronos y, con
    // una cola de launchd rota (LWCR obsoleto), un mensaje puede perderse o entregarse
    // tarde y dejar el SMC en un estado que la app cree distinto. F#Md se puede leer
    // sin privilegios, así que se compara la realidad con lo deseado *en este momento*
    // y se reenvía una sola vez si no cuadra.
    private func scheduleFanPolicyVerification() {
        pendingFanVerification += 1
        let generation = pendingFanVerification
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pendingFanVerification == generation else { return }
            let desired = self.lastOnACPower && self.aggressiveFansEnabled
                && ProcessInfo.processInfo.thermalState == .nominal
            let mismatch = (0..<self.fanCount).contains { index in
                let mode = "F\(index)Md".withCString { SMCGetFloatValue($0) }
                return mode >= 0 && (mode >= 0.5) != desired
            }
            guard mismatch else { return }
            NSLog("Estado de ventiladores no coincide con la política (¿mensaje perdido?); reintentando")
            self.appliedAggressiveFans = !desired
            self.applyFanPolicy(onAC: self.lastOnACPower, isRetry: true)
        }
    }

    private func helperService() -> SMAppService {
        SMAppService.daemon(plistName: Self.helperPlistName)
    }

    private func ensureHelperRegistered(openSettings: Bool) {
        let service = helperService()
        // register() también actualiza un registro existente, y es imprescindible tras
        // cada recompilación: la aprobación fija el requisito de código (LWCR) del
        // binario del helper y con firma ad-hoc cada build cambia el hash. Sin este
        // re-registro launchd deja el daemon en "spawn failed" (EX_CONFIG) y los
        // mensajes XPC se quedan encolados para siempre.
        do {
            try service.register()
        } catch {
            NSLog("Registro del helper: \(error)")
        }
        if openSettings && service.status != .enabled {
            // Falta la aprobación del usuario: llevarle directamente al panel.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // La aprobación del daemon fija un requisito de código (LWCR) sobre el hash del
    // binario; con firma ad-hoc cada recompilación lo invalida y launchd deja el helper
    // en "spawn failed" con los mensajes XPC encolados para siempre. register() a secas
    // no refresca el LWCR: hay que des-registrar y volver a registrar. Este ping detecta
    // el estado (un helper sano responde status -1 al fan inválido sin tocar el SMC).
    private func verifyHelperAndRepairIfNeeded() {
        var answered = false
        let connection = helperXPCConnection()
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, "fan", -1)
        xpc_connection_send_message_with_reply(connection, message, DispatchQueue.main) { _ in
            answered = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !answered else { return }
            NSLog("Helper sin respuesta; re-registrando el daemon")
            let service = self.helperService()
            try? service.unregister()
            // BTM procesa el des-registro de forma asíncrona: registrar de inmediato
            // puede reciclar el registro viejo con su LWCR obsoleto y quedar "enabled"
            // sin pedir aprobación nueva (launchd sigue en EX_CONFIG). La pausa deja
            // que el registro viejo muera de verdad antes de crear el nuevo.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                do {
                    try service.register()
                } catch {
                    NSLog("Re-registro del helper: \(error)")
                }
                self.helperConnection = nil
                self.updateAggressiveFansMenuItem()
                if service.status == .enabled {
                    self.applyFanPolicy(onAC: self.lastOnACPower)
                } else if self.aggressiveFansEnabled {
                    // Falta aprobación del usuario: llevarle al panel directamente.
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
    }

    private func helperXPCConnection() -> xpc_connection_t {
        if let connection = helperConnection {
            return connection
        }
        // 2 == XPC_CONNECTION_MACH_SERVICE_PRIVILEGED (macro no importable desde Swift):
        // el servicio vive en el bootstrap privilegiado porque el helper es un daemon.
        let connection = xpc_connection_create_mach_service(Self.helperServiceName, DispatchQueue.main, 2)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            // Aquí solo llegan errores (helper aún no aprobado, reinstalado…): se descarta
            // la conexión cacheada para recrearla limpia en el siguiente uso.
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self?.helperConnection = nil
            }
        }
        xpc_connection_activate(connection)
        helperConnection = connection
        return connection
    }

    private func sendFanCommand(fanIndex: Int, forced: Bool, rpm: Double, synchronous: Bool) {
        let connection = helperXPCConnection()
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, "fan", Int64(fanIndex))
        xpc_dictionary_set_int64(message, "mode", forced ? 1 : 0)
        xpc_dictionary_set_double(message, "rpm", rpm)
        if synchronous {
            // Con timeout: si launchd no puede lanzar el helper, una espera síncrona
            // sin límite bloquearía la salida de la app indefinidamente.
            let semaphore = DispatchSemaphore(value: 0)
            xpc_connection_send_message_with_reply(connection, message, nil) { [weak self] reply in
                self?.logFanWriteReplyIfFailed(reply, fanIndex: fanIndex)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
        } else {
            xpc_connection_send_message_with_reply(connection, message, DispatchQueue.main) { [weak self] reply in
                self?.logFanWriteReplyIfFailed(reply, fanIndex: fanIndex)
            }
        }
    }

    private func logFanWriteReplyIfFailed(_ reply: xpc_object_t, fanIndex: Int) {
        if xpc_get_type(reply) == XPC_TYPE_ERROR || xpc_dictionary_get_int64(reply, "status") != 0 {
            NSLog("No se pudo ajustar el mínimo del ventilador \(fanIndex) (¿helper aprobado en Ajustes?)")
        }
    }

    private func updateAggressiveFansMenuItem() {
        guard let item = statusItem.menu?.item(withTag: 105) else { return }
        if let submenu = item.submenu {
            for subItem in submenu.items {
                subItem.state = (aggressiveFansEnabled && subItem.tag == fanIntensityPercent)
                    || (!aggressiveFansEnabled && subItem.tag == 0) ? .on : .off
            }
        }
        if aggressiveFansEnabled && helperService().status != .enabled {
            item.title = NSLocalizedString("fans.aggressive.title.pendingApproval", comment: "Ventiladores agresivos: helper pendiente de aprobar")
        } else if aggressiveFansEnabled && ProcessInfo.processInfo.thermalState != .nominal {
            item.title = NSLocalizedString("fans.aggressive.title.thermalPause", comment: "Ventiladores agresivos: en pausa por carga térmica")
        } else {
            item.title = NSLocalizedString("fans.aggressive.title", comment: "Submenú: intensidad de ventiladores, solo con cargador")
        }
    }

    // ¿Es una interfaz Ethernet "de verdad" (cable/dock) y no virtual (PAN BT, tethering)?
    // Sube por la cadena de providers en el IORegistry acumulando clases: el PAN de
    // Bluetooth y el tethering USB de iPhone/iPad se anuncian como Ethernet ante
    // SystemConfiguration pero cuelgan de proveedores IOKit reconocibles. Es
    // independiente del idioma del sistema, a diferencia de comparar el nombre mostrado.
    private func isPhysicalEthernet(bsdName: String) -> Bool {
        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            var current = entry
            IOObjectRetain(current)
            while current != IO_OBJECT_NULL {
                var className = [CChar](repeating: 0, count: 128)
                IOObjectGetClass(current, &className)
                let name = String(cString: className)
                // Virtuales conocidas: PAN de Bluetooth e iPhone/iPad por USB.
                if name.contains("Bluetooth") || name == "IOUserEthernetController"
                    || name.hasPrefix("AppleUSBDeviceNCM") {
                    IOObjectRelease(current)
                    return false
                }
                var parent: io_registry_entry_t = 0
                let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                IOObjectRelease(current)
                current = (kr == KERN_SUCCESS) ? parent : IO_OBJECT_NULL
            }
            entry = IOIteratorNext(iterator)
        }
        return true
    }

    private func isEthernetConnected() -> Bool {
        guard let store = dynamicStore ?? SCDynamicStoreCreate(nil, "PlugPilot" as CFString, nil, nil),
              let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return false
        }

        for interface in interfaces {
            guard SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeEthernet,
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) else { continue }

            guard isPhysicalEthernet(bsdName: bsdName as String) else { continue }

            // Red de seguridad adicional además del filtro por IORegistry: barata y no
            // hace daño si alguna variante virtual se nos escapa por ahí.
            if let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
               displayName.contains("Bluetooth") || displayName.contains("iPhone") || displayName.contains("iPad") {
                continue
            }

            let linkKey = "State:/Network/Interface/\(bsdName)/Link" as CFString
            if let linkInfo = SCDynamicStoreCopyValue(store, linkKey) as? [String: Any],
               let active = linkInfo["Active"] as? Bool, active {
                return true
            }
        }
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        // No hay notificación del sistema cuando el usuario aprueba el helper en Ajustes;
        // reaplicar aquí (idempotente y solo si la función está en uso) cubre ese caso
        // sin recurrir a polling.
        applyFanPolicy(onAC: lastOnACPower)
        updateAggressiveFansMenuItem()
        updateStatusMenu()
        updateTemperatureMenuItem()
        updateBatteryTemperatureMenuItem()
        updateFanMenuItem()
    }

    private static let cpuTemperatureKeys = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H", "TCXC"]
    private static let batteryTemperatureKeys = ["TB0T", "TB1T", "TB2T"]

    private func readTemperature(candidateKeys: [String]) -> Double? {
        for key in candidateKeys {
            let temperature = key.withCString { SMCGetTemperature($0) }
            if temperature > 0 && temperature < 120 {
                return temperature
            }
        }
        return nil
    }

    private func updateTemperatureMenuItem() {
        guard let item = statusItem.menu?.item(withTag: 102) else { return }
        if let temperature = readTemperature(candidateKeys: Self.cpuTemperatureKeys) {
            item.title = String(format: NSLocalizedString("cpu.temperature.format", comment: "Temperatura de CPU, %.1f°C"), temperature)
        } else {
            item.title = NSLocalizedString("cpu.temperature.unavailable", comment: "Temperatura de CPU no disponible")
        }
    }

    private func updateBatteryTemperatureMenuItem() {
        guard let item = statusItem.menu?.item(withTag: 103) else { return }
        if let temperature = readTemperature(candidateKeys: Self.batteryTemperatureKeys) {
            item.title = String(format: NSLocalizedString("battery.temperature.format", comment: "Temperatura de batería, %.1f°C"), temperature)
        } else {
            item.title = NSLocalizedString("battery.temperature.unavailable", comment: "Temperatura de batería no disponible")
        }
    }

    private func updateFanMenuItem() {
        guard let item = statusItem.menu?.item(withTag: 104) else { return }
        guard fanCount > 0 else {
            item.title = NSLocalizedString("fans.unavailable", comment: "Sin ventiladores disponibles")
            return
        }

        let readings = (0..<fanCount).map { index -> String in
            let actual = "F\(index)Ac".withCString { SMCGetFloatValue($0) }
            let maximum = "F\(index)Mx".withCString { SMCGetFloatValue($0) }
            guard actual >= 0, maximum > 0 else {
                return String(format: NSLocalizedString("fan.reading.unavailable.format", comment: "Lectura de ventilador no disponible, %d = índice"), index)
            }
            let percent = Int((actual / maximum) * 100)
            return String(format: NSLocalizedString("fan.reading.format", comment: "Lectura de ventilador: índice, rpm, porcentaje"), index, Int(actual), percent)
        }
        item.title = readings.joined(separator: " · ")
    }

    private func setWiFiPower(_ on: Bool) {
        guard let wifiInterface = CWWiFiClient.shared().interface() else { return }
        guard wifiInterface.powerOn() != on else { return }
        do {
            try wifiInterface.setPower(on)
        } catch {
            NSLog("No se pudo cambiar el estado de Wi-Fi: \(error)")
        }
    }

    private func updateStatusMenu() {
        if let item = statusItem.menu?.item(withTag: 100) {
            let accessibilityDescription = NSLocalizedString("accessibility.power", comment: "Descripción de accesibilidad del icono de alimentación")
            if hasBattery {
                item.title = lastOnACPower
                    ? NSLocalizedString("status.onAC", comment: "Cargador conectado")
                    : NSLocalizedString("status.onBattery", comment: "En batería")
                item.image = NSImage(systemSymbolName: lastOnACPower ? "powerplug.fill" : "battery.100percent",
                                     accessibilityDescription: accessibilityDescription)
            } else {
                item.title = NSLocalizedString("status.acOnly", comment: "Máquina sin batería, siempre con corriente")
                item.image = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: accessibilityDescription)
            }
        }
        if let item = statusItem.menu?.item(withTag: 106) {
            // Estado real del controlador, no el que "debería" tener según la alimentación.
            // ON/OFF se dejan sin traducir: es la abreviatura habitual también en español.
            let bluetoothOn = IOBluetoothPreferenceGetControllerPowerState() != 0
            item.title = String(format: NSLocalizedString("bluetooth.status.format", comment: "Estado de Bluetooth, %@ = ON/OFF"), bluetoothOn ? "ON" : "OFF")
        }
        if let item = statusItem.menu?.item(withTag: 101) {
            let wifiOn = CWWiFiClient.shared().interface()?.powerOn() ?? true
            let wifiTitle = String(format: NSLocalizedString("wifi.status.format", comment: "Estado de Wi-Fi, %@ = ON/OFF"), wifiOn ? "ON" : "OFF")
            item.image = NSImage(systemSymbolName: wifiOn ? "wifi" : "wifi.slash", accessibilityDescription: "Wi-Fi")
            if lastEthernetActive {
                // El icono de Ethernet va incrustado en el texto (el hueco de imagen del
                // item ya lo ocupa el de Wi-Fi).
                let font = NSFont.menuFont(ofSize: 0)
                let title = NSMutableAttributedString(string: "\(wifiTitle) · ", attributes: [.font: font])
                let attachment = NSTextAttachment()
                attachment.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Ethernet")
                attachment.bounds = NSRect(x: 0, y: font.descender + 1, width: font.pointSize, height: font.pointSize)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: NSLocalizedString("wifi.status.ethernet.suffix", comment: "Sufijo ' Ethernet' tras el icono"), attributes: [.font: font]))
                item.attributedTitle = title
            } else {
                item.attributedTitle = nil
                item.title = wifiTitle
            }
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSLog("No se pudo cambiar el login item: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
