# Modelos y proveedores en SnapIt

SnapIt no trae modelos propios: usa los que ya tienes configurados en **Hermes
Agent**. Este documento explica cómo agregarlos y cuál elegir.

---

## 1. Por qué importa tanto el modelo

El flujo de SnapIt es:

```
captura PNG  ->  Hermes + modelo  ->  prompt mejorado  ->  agente / web
```

Ese paso del medio recibe **una imagen**. Por eso:

- Si el modelo **ve imágenes** → SnapIt entiende qué hay en pantalla y escribe un
  prompt preciso.
- Si el modelo es **solo texto** → no puede leer la captura, el prompt sale vacío o
  genérico, y SnapIt avisa de que no pudo ver la imagen.
- Si **no hay modelo** → SnapIt sigue funcionando, pero usa un texto genérico en
  lugar del prompt mejorado.

> Regla práctica: **el modelo por defecto de Hermes debe ser multimodal.**

---

## 2. Proveedor ≠ modelo

- **Proveedor**: quién sirve el modelo (OpenAI, Anthropic, Gemini, DeepSeek,
  OpenRouter, tu LM Studio local...). Se identifica con un id, por ejemplo
  `openai-api` o `anthropic`.
- **Modelo**: el nombre exacto que pides, por ejemplo `gpt-4o`,
  `claude-sonnet-4-5`, `gemini-2.5-flash`.

En Hermes se configuran así:

```yaml
model:
  provider: openai-api
  default: gpt-4o
```

Las credenciales van aparte, en el `.env` de Hermes
(`%LOCALAPPDATA%\hermes\.env`).

---

## 3. Tres formas de agregar un modelo

### A. El asistente de SnapIt (gráfico)

Paso 3 del instalador: eliges proveedor, pegas la API key y pulsas **Guardar
credencial**. Luego escribes proveedor + modelo y pulsas **Aplicar modelo por
defecto**. Al final, **Probar ahora**.

### B. El selector oficial de Hermes

```powershell
hermes model          # selector interactivo: proveedor + modelo + credencial
hermes setup model    # asistente completo del paso de modelo
hermes auth add anthropic --type api-key --api-key TU_CLAVE --label SnapIt
```

### C. Directo al `.env`

Añade la variable del proveedor a `%LOCALAPPDATA%\hermes\.env`:

```
OPENROUTER_API_KEY=sk-or-v1-...
```

y fija el modelo:

```powershell
hermes config set model.provider openrouter
hermes config set model.default google/gemini-2.5-flash
```

---

## 4. Proveedores que Hermes reconoce

| Proveedor | id | Variable en `.env` | Notas |
|---|---|---|---|
| Nous Portal | `nous` | — (login en navegador) | El más rápido si no tienes claves. |
| OpenAI | `openai-api` | `OPENAI_API_KEY` | Modelos GPT con visión. |
| Anthropic | `anthropic` | `ANTHROPIC_API_KEY` | Claude entiende muy bien las imágenes. |
| Google Gemini | `gemini` | `GEMINI_API_KEY` | Tiene capa gratuita y visión. |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` | Barato y rápido. |
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` | Una sola clave para cientos de modelos. |
| xAI Grok | `xai` | `XAI_API_KEY` | |
| Moonshot Kimi | `kimi-coding` | `KIMI_API_KEY` | |
| Z.ai GLM | `zai` | `GLM_API_KEY` | |
| MiniMax | `minimax` | `MINIMAX_API_KEY` | |
| Alibaba Qwen | `alibaba` | `DASHSCOPE_API_KEY` | |
| NVIDIA NIM | `nvidia` | `NVIDIA_API_KEY` | |
| Hugging Face | `huggingface` | `HF_TOKEN` | |
| Ollama Cloud | `ollama-cloud` | `OLLAMA_API_KEY` | |
| LM Studio (local) | `lmstudio` | `LM_API_KEY` + `LM_BASE_URL` | Sin coste, corre en tu PC. |
| Azure AI Foundry | `azure-foundry` | `AZURE_FOUNDRY_API_KEY` | |
| Google Vertex | `vertex` | — (login de Google Cloud) | |
| GitHub Copilot | `copilot` | `COPILOT_GITHUB_TOKEN` | |

Puedes comprobar qué claves tienes ya guardadas con `hermes status`.

---

## 5. Modelos con visión recomendados

Los nombres cambian con el tiempo; estos son los que suelen funcionar bien:

| Proveedor | Modelo de ejemplo |
|---|---|
| OpenAI | `gpt-4o`, `gpt-4.1`, `gpt-4o-mini` |
| Anthropic | `claude-sonnet-4-5`, `claude-haiku-4-5` |
| Google | `gemini-2.5-flash`, `gemini-2.5-pro` |
| OpenRouter | cualquier modelo multimodal (`google/gemini-2.5-flash`, `qwen/qwen2.5-vl-72b`...) |
| Local (LM Studio) | `qwen2.5-vl`, `llava`, `gemma-3-4b-it` (los que acepten imagen) |

Si tienes dudas, ejecuta en una consola:

```powershell
hermes model --refresh
```

Muestra la lista viva de modelos de cada proveedor.

---

## 6. Usar un modelo distinto solo para mejorar prompts

No hace falta que el mejorador sea el mismo modelo que usan tus agentes.
En `%USERPROFILE%\.snapit\config.json`:

```jsonc
{
  "improverProfile": "default",     // perfil de Hermes que lee la captura
  "improverModel": "gpt-4o"         // modelo con visión solo para esto
}
```

`improverModel` vacío significa "usa el modelo por defecto del perfil".

---

## 7. Modelos locales (sin coste, sin internet)

Con **LM Studio**:

1. En LM Studio, carga un modelo multimodal y activa el servidor local
   (por defecto `http://127.0.0.1:1234`).
2. En Hermes:

   ```powershell
   hermes config set model.provider lmstudio
   hermes config set model.default NOMBRE-DEL-MODELO-CARGADO
   ```

3. En `%LOCALAPPDATA%\hermes\.env`:

   ```
   LM_BASE_URL=http://127.0.0.1:1234/v1
   LM_API_KEY=lm-studio
   ```

Con **Ollama** local puedes apuntar un proveedor personalizado a
`http://127.0.0.1:11434/v1` usando `hermes model`.

---

## 8. Verificar y depurar

```powershell
hermes status                     # claves cargadas y modelo activo
hermes config get model           # proveedor y modelo por defecto
hermes -p default chat -Q -q "Responde unicamente con: SNAPIT-OK"
```

Prueba de visión real (usa una captura de SnapIt):

```powershell
hermes -p default chat -Q -q "Describe en una linea que se ve en esta imagen" --image "$env:USERPROFILE\.snapit\captures\ARCHIVO.png"
```

Si esa orden funciona, el prompt mejorado de SnapIt también va a funcionar.

| Síntoma | Qué revisar |
|---|---|
| Prompt vacío o genérico | El modelo no es multimodal, o la imagen no llegó. Prueba la orden de arriba. |
| `401` / `403` | Clave incorrecta o sin saldo. Revisa `hermes status`. |
| `model not found` | El nombre del modelo no existe en ese proveedor. Usa `hermes model --refresh`. |
| Timeout | El modelo tarda más de lo que SnapIt espera (300 s). Prueba un modelo más rápido. |
| Cambié de modelo y no pasa nada | SnapIt lee el perfil en cada captura, pero el agente que ya está abierto conserva su modelo. Cierra esa sesión y vuelve a capturar. |
| No quiero gastar en el mejorador | Pon `improverModel` a un modelo barato con visión, o usa un modelo local con LM Studio. |
