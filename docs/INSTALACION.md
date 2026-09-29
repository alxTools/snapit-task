# Instalación de SnapIt

Guía completa, de cero a "ya está funcionando". Si prefieres el camino corto:
haz doble clic en **`Instalar SnapIt.cmd`** y sigue el asistente.

---

## 1. Antes de empezar

| Necesitas | ¿Obligatorio? | Por qué |
|---|---|---|
| Windows 10 u 11 | Sí | SnapIt usa WPF y atajos globales de Windows. |
| Windows PowerShell 5.1 | Sí | Ya viene con Windows (`powershell.exe`). No hay que instalar nada. |
| **Hermes Agent CLI** | Sí | Es el motor: mejora el prompt y ejecuta los agentes. |
| **Un modelo con visión configurado en Hermes** | Sí | SnapIt le manda tu captura como imagen. |
| Node.js 22+ | No | Solo para pegar el prompt automáticamente en la ruta web. Sin Node, se copia al portapapeles. |
| Microsoft Edge | No | Solo para abrir el destino web en una ventana aislada. Viene con Windows. |

No se necesita permiso de administrador. Todo se escribe en:

- `%USERPROFILE%\.snapit\` → configuración, capturas, borradores, registros.
- `%LOCALAPPDATA%\hermes\` → el `.env` y los perfiles de Hermes.

---

## 2. Instalación con el asistente gráfico (recomendado)

Doble clic en **`Instalar SnapIt.cmd`** (está en la raíz del repositorio), o desde
una terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\SnapIt-Setup.ps1
```

El asistente tiene seis pasos.

### Paso 1 · Bienvenida

Qué hace SnapIt y qué va a hacer el asistente. Nada se envía a ningún servicio.

### Paso 2 · Requisitos

Comprueba en vivo tu PC y marca cada línea:

- `[ OK ]` verde → listo.
- `[FALTA]` rojo → es obligatorio; abajo te dice qué hacer.
- `[ -- ]` amarillo → es opcional; SnapIt funciona igual.

Puedes pulsar **Volver a comprobar** las veces que quieras. Si sigues adelante con
algo obligatorio en rojo, el asistente te avisa.

### Paso 3 · Agregar los modelos ← el paso importante

Aquí es donde SnapIt aprende a pensar. Tienes tres caminos y puedes combinarlos:

**A. Pegar una API key.** Elige el proveedor en la lista, pega la clave y pulsa
**Guardar credencial**. El asistente ejecuta `hermes auth add <proveedor>` y, si esa
orden no está disponible en tu versión, escribe la clave en el `.env` de Hermes.
El botón **Abrir la página de la API key** te lleva al sitio del proveedor.

**B. Iniciar sesión con Nous Portal.** Elige `Nous Portal` en la lista y pulsa
**Iniciar sesión / elegir modelo**. Se abre una consola con el selector oficial de
Hermes (`hermes model`) donde eliges proveedor y modelo con el teclado. Si no tienes
ninguna clave, este es el camino más rápido.

**C. Escribir el modelo por defecto a mano.** En el **Paso B** escribe el proveedor y
el nombre exacto del modelo, y pulsa **Aplicar modelo por defecto**. SnapIt ejecuta
`hermes config set model.provider` y `hermes config set model.default`.

Cuando termines, pulsa **Probar ahora**: SnapIt lanza una consulta real y te muestra
la respuesta del modelo. Si responde, ya está conectado.

> **Lo más importante de todo:** el modelo tiene que **ver imágenes**. SnapIt manda
> la captura como imagen; un modelo solo-texto devolverá un prompt vacío y SnapIt
> caerá a un texto genérico. Lista de proveedores, variables de entorno y modelos
> recomendados: **[MODELOS.md](MODELOS.md)**.

### Paso 4 · Opciones

- **Iniciar con Windows** (con vigilante que lo reinicia si se cae).
- **Crear el perfil Hermes `snapit`** (recomendado): un clon de tu perfil `default`
  con instrucciones propias para entender las capturas.
- **Que los agentes trabajen sin pedir permiso** (`--yolo`). Si lo desmarcas, cada
  agente pedirá confirmación antes de hacer algo peligroso.
- **Atajo de captura**: por defecto `Alt+Shift+S`.
- **Destino web**: por defecto `http://127.0.0.1:18080` (tu UI de DeepSeek/DSH).
- **Voz (opcional)**: API key de ElevenLabs y agent id para `Alt+Shift+A`.

### Paso 5 · Instalar

Pulsa **Instalar SnapIt**. El asistente escribe `~/.snapit/config.json`, ejecuta
`setup.ps1` (crea el perfil `snapit` y su SOUL, y configura el arranque) y verifica
que el perfil responde. Todo se ve en el registro en vivo, y queda copiado en
`%USERPROFILE%\.snapit\logs\install.log`.

### Paso 6 · Listo

**Iniciar SnapIt ahora** deja el icono en la bandeja del sistema. Pulsa
**Alt+Shift+S** en cualquier momento.

---

## 3. Instalación sin interfaz

Útil para equipos remotos, scripts o CI:

```powershell
# comprueba requisitos, instala y sale
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\SnapIt-Setup.ps1 -Unattended

# además, arranque automático con Windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\SnapIt-Setup.ps1 -Unattended -AutoStart

# sin crear el perfil de agente
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\SnapIt-Setup.ps1 -Unattended -SkipProfileClone
```

---

## 4. Instalación manual (sin asistente)

```powershell
git clone <url-del-repo> snapit-task
cd snapit-task

# 1) configura Hermes: proveedor, modelo y credencial
hermes model

# 2) configuración de SnapIt, perfil "snapit" y SOUL
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1

# 3) (opcional) arrancar con Windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -AutoStart

# 4) ejecutar
powershell -NoProfile -ExecutionPolicy Bypass -File .\snapit.ps1
```

---

## 5. Comprobar que quedó bien

```powershell
# ¿hay proveedor y modelo por defecto?
hermes config get model

# ¿responde el modelo?
hermes -p default chat -Q -q "Responde unicamente con: SNAPIT-OK"

# ¿existe el perfil de agente de SnapIt?
hermes -p snapit --version

# captura única y salir (prueba el flujo completo)
powershell -NoProfile -ExecutionPolicy Bypass -File .\snapit.ps1 -Once
```

Si los cuatro responden, SnapIt quedó exactamente como en la máquina de desarrollo.

---

## 6. Desinstalar

```powershell
# 1) salir de SnapIt desde el icono de la bandeja ("Exit SnapIt")
#    (escribe ~/.snapit/.exit para que el vigilante no lo relance)

# 2) quitar el arranque automático
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'SnapIt.cmd') -ErrorAction SilentlyContinue

# 3) borrar datos de SnapIt (capturas, borradores, configuración)
Remove-Item "$env:USERPROFILE\.snapit" -Recurse -Force

# 4) borrar el perfil de agente (opcional)
hermes profile delete snapit
```

Las credenciales viven en `%LOCALAPPDATA%\hermes\.env`; el asistente hace una copia
de seguridad (`.snapit-backup-*`) cada vez que modifica ese archivo.

---

## 7. Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| El instalador dice que falta Hermes | Instala Hermes Agent y vuelve a abrirlo. Busca `hermes.exe` en el PATH y en `%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\`. |
| El paso 3 dice "no hay modelo por defecto" | Todavía no configuraste proveedor. Usa la opción A o B del paso 3. |
| "El modelo no respondió" al probar | Clave incorrecta, sin saldo, o el nombre del modelo no existe. Prueba `hermes model` en una consola. |
| El prompt mejorado sale genérico | El modelo no ve imágenes. Cambia a uno multimodal o define `improverModel` (ver [MODELOS.md](MODELOS.md)). |
| El atajo no dispara | Otro programa tiene tomado `Alt+Shift+S`. Cambia `hotkey` en Opciones o cierra ese programa. |
| No aparece el destino web | Es opcional: sin Node.js o sin Edge, SnapIt copia el prompt al portapapeles de todos modos. |
| Quiero ver qué pasó | `%USERPROFILE%\.snapit\logs\snapit.log` e `install.log`. |
