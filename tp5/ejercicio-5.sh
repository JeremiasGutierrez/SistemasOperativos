#!/usr/bin/env bash

PUERTO=8080
DIR_BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DATOS="$DIR_BASE/data.sq3"
LOG_SISTEMA="$DIR_BASE/system.log"
LOG_ERRORES="$DIR_BASE/error.log"
ARCH_REPORTE="$DIR_BASE/productos.html"

SESION_USUARIO_ID=""
SESION_USUARIO_NOMBRE=""

registrar_log() {
    local accion="$1"
    local fecha_hora
    fecha_hora=$(date "+%Y-%m-%d %H:%M:%S")
    local uid="${SESION_USUARIO_ID:--}"
    local uname="${SESION_USUARIO_NOMBRE:--}"
    printf "%s\t%s\t%s\t%s\n" "$fecha_hora" "$uid" "$uname" "$accion" >> "$LOG_SISTEMA"
}

registrar_error() {
    local mensaje="$1"
    local fecha_hora
    fecha_hora=$(date "+%Y-%m-%d %H:%M:%S")
    printf "%s\t%s\n" "$fecha_hora" "$mensaje" >> "$LOG_ERRORES"
}

ejecutar_sql() {
    local sql="$1"
    local resultado
    resultado=$(sqlite3 "$BASE_DATOS" "$sql" 2>&1)
    local codigo=$?
    if (( codigo != 0 )); then
        registrar_error "SQL Error: $resultado | Sentencia: $sql"
        return 1
    fi
    [[ -n "$resultado" ]] && echo "$resultado"
    return 0
}

inicializar_base_datos() {
    if [[ -f "$BASE_DATOS" ]]; then
        return 0
    fi
    local sql_creacion="
        CREATE TABLE IF NOT EXISTS usuarios (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            nombre      TEXT    UNIQUE NOT NULL,
            hash_clave  TEXT    NOT NULL
        );
        CREATE TABLE IF NOT EXISTS productos (
            id      TEXT PRIMARY KEY,
            nombre  TEXT NOT NULL,
            precio  TEXT NOT NULL
        );
    "
    sqlite3 "$BASE_DATOS" "$sql_creacion" 2>/dev/null
}

calcular_hash() {
    local clave="$1"
    local hash_raw
    hash_raw=$(echo -n "$clave" | sha256sum)
    local hash_limpio="${hash_raw:0:64}"
    echo "$hash_limpio"
}

get_param() {
    local key="$1"
    local qs="$2"
    local pair
    IFS='&' read -ra pairs <<< "$qs"
    for pair in "${pairs[@]}"; do
        if [[ "$pair" == "$key="* ]]; then
            local val="${pair#"$key="}"
            val="${val//+/ }"
            printf '%b' "${val//%/\\x}"
            return 0
        fi
    done
    echo ""
}

rpc_login() {
    local usuario="$1"
    local clave="$2"
    if [[ -z "$usuario" || -z "$clave" ]]; then
        echo '{"ok":false,"error":"Debe ingresar usuario y contrasena."}'
        return 1
    fi
    local hash_ingresado
    hash_ingresado=$(calcular_hash "$clave")
    local resultado
    resultado=$(ejecutar_sql "SELECT id, nombre FROM usuarios WHERE nombre = '$usuario' AND hash_clave = '$hash_ingresado';")
    if [[ -n "$resultado" ]]; then
        local uid
        local uname
        uid=$(echo "$resultado" | cut -d'|' -f1)
        uname=$(echo "$resultado" | cut -d'|' -f2)
        SESION_USUARIO_ID="$uid"
        SESION_USUARIO_NOMBRE="$uname"
        registrar_log "INICIO_SESION"
        echo "{\"ok\":true,\"usuario_id\":\"$uid\",\"usuario_nombre\":\"$uname\",\"mensaje\":\"Bienvenido/a $uname\"}"
        return 0
    fi
    registrar_error "Login fallido desde Web: credenciales incorrectas para usuario '$usuario'."
    registrar_log "LOGIN_FALLIDO: $usuario"
    echo '{"ok":false,"error":"Credenciales incorrectas."}'
    return 1
}

rpc_registro() {
    local usuario="$1"
    local clave="$2"
    if [[ -z "$usuario" || -z "$clave" ]]; then
        echo '{"ok":false,"error":"Usuario y contrasena no pueden estar vacios."}'
        registrar_error "Registro fallido desde Web: campos vacios."
        return 1
    fi
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM usuarios WHERE nombre = '$usuario';")
    if [[ "$cantidad" -gt 0 ]] 2>/dev/null; then
        echo '{"ok":false,"error":"El usuario ya se encuentra registrado."}'
        registrar_error "Registro fallido desde Web: usuario '$usuario' ya existe."
        return 1
    fi
    local hash_clave
    hash_clave=$(calcular_hash "$clave")
    if ! ejecutar_sql "INSERT INTO usuarios (nombre, hash_clave) VALUES ('$usuario', '$hash_clave');"; then
        echo '{"ok":false,"error":"Error al registrar el usuario en la base de datos."}'
        registrar_error "Registro fallido desde Web: error SQL al insertar usuario '$usuario'."
        return 1
    fi
    registrar_log "REGISTRO_USUARIO: $usuario"
    echo "{\"ok\":true,\"mensaje\":\"Usuario '$usuario' registrado exitosamente.\"}"
    return 0
}

rpc_listar() {
    local uid="$1"
    local uname="$2"
    SESION_USUARIO_ID="$uid"
    SESION_USUARIO_NOMBRE="$uname"
    local filas
    filas=$(ejecutar_sql "SELECT id, nombre, precio FROM productos ORDER BY id;")
    local json_items=""
    local primero=1
    while IFS='|' read -r pid pnom pprec; do
        [[ -z "$pid" ]] && continue
        local id_esc="${pid//\"/\\\"}"
        local nom_esc="${pnom//\"/\\\"}"
        local prec_esc="${pprec//\"/\\\"}"
        if (( primero == 1 )); then
            primero=0
            json_items="{\"id\":\"$id_esc\",\"nombre\":\"$nom_esc\",\"precio\":\"$prec_esc\"}"
        else
            json_items="$json_items,{\"id\":\"$id_esc\",\"nombre\":\"$nom_esc\",\"precio\":\"$prec_esc\"}"
        fi
    done <<< "$filas"
    registrar_log "MOSTRAR_INVENTARIO"
    echo "{\"ok\":true,\"productos\":[$json_items]}"
}

rpc_alta() {
    local id="$1"
    local nombre="$2"
    local precio="$3"
    local uid="$4"
    local uname="$5"
    SESION_USUARIO_ID="$uid"
    SESION_USUARIO_NOMBRE="$uname"
    if [[ -z "$id" || -z "$nombre" || -z "$precio" ]]; then
        echo '{"ok":false,"error":"Todos los campos son obligatorios."}'
        registrar_error "Alta fallida desde Web: campos vacios."
        return 1
    fi
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos WHERE id = '$id';")
    if [[ "$cantidad" -gt 0 ]] 2>/dev/null; then
        echo '{"ok":false,"error":"Ya existe un producto con el ID especificado."}'
        registrar_error "Alta fallida desde Web: producto ID '$id' ya existe."
        return 1
    fi
    if ! ejecutar_sql "INSERT INTO productos (id, nombre, precio) VALUES ('$id', '$nombre', '$precio');"; then
        echo '{"ok":false,"error":"Error al registrar producto en la base de datos."}'
        registrar_error "Alta fallida desde Web: error SQL ID '$id'."
        return 1
    fi
    registrar_log "ALTA_PRODUCTO: ID=$id, Nombre=$nombre, Precio=$precio"
    echo "{\"ok\":true,\"mensaje\":\"Producto '$nombre' (ID: $id) guardado con precio \$$precio.\"}"
    return 0
}

rpc_baja() {
    local id="$1"
    local uid="$2"
    local uname="$3"
    SESION_USUARIO_ID="$uid"
    SESION_USUARIO_NOMBRE="$uname"
    if [[ -z "$id" ]]; then
        echo '{"ok":false,"error":"El ID del producto es obligatorio."}'
        return 1
    fi
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos WHERE id = '$id';")
    if [[ "$cantidad" -eq 0 ]] 2>/dev/null; then
        echo '{"ok":false,"error":"El producto no existe."}'
        registrar_error "Baja fallida desde Web: producto ID '$id' no existe."
        return 1
    fi
    if ! ejecutar_sql "DELETE FROM productos WHERE id = '$id';"; then
        echo '{"ok":false,"error":"Error al eliminar producto en la base de datos."}'
        registrar_error "Baja fallida desde Web: error SQL ID '$id'."
        return 1
    fi
    registrar_log "BAJA_PRODUCTO: ID=$id"
    echo "{\"ok\":true,\"mensaje\":\"Producto con ID '$id' eliminado correctamente.\"}"
    return 0
}

rpc_editar() {
    local id="$1"
    local nombre="$2"
    local precio="$3"
    local uid="$4"
    local uname="$5"
    SESION_USUARIO_ID="$uid"
    SESION_USUARIO_NOMBRE="$uname"
    if [[ -z "$id" || -z "$nombre" || -z "$precio" ]]; then
        echo '{"ok":false,"error":"Todos los campos son requeridos."}'
        return 1
    fi
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos WHERE id = '$id';")
    if [[ "$cantidad" -eq 0 ]] 2>/dev/null; then
        echo '{"ok":false,"error":"El producto no existe."}'
        registrar_error "Edicion fallida desde Web: producto ID '$id' no existe."
        return 1
    fi
    if ! ejecutar_sql "UPDATE productos SET nombre = '$nombre', precio = '$precio' WHERE id = '$id';"; then
        echo '{"ok":false,"error":"Error al actualizar en la base de datos."}'
        registrar_error "Edicion fallida desde Web: error SQL ID '$id'."
        return 1
    fi
    registrar_log "EDITAR_PRODUCTO: ID=$id, NuevoNombre=$nombre, NuevoPrecio=$precio"
    echo "{\"ok\":true,\"mensaje\":\"Producto con ID '$id' modificado exitosamente.\"}"
    return 0
}

rpc_reporte_html() {
    local uid="$1"
    local uname="$2"
    SESION_USUARIO_ID="$uid"
    SESION_USUARIO_NOMBRE="$uname"

    cat <<EOF > "$ARCH_REPORTE"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Reporte de Productos</title>
    <style>
        body { font-family: Arial, sans-serif; background-color: #f7f9fc; color: #2c3e50; margin: 0; padding: 30px; }
        .container { max-width: 800px; margin: 0 auto; background: #ffffff; border-radius: 8px; padding: 24px; box-shadow: 0 4px 10px rgba(0,0,0,0.08); }
        h1 { text-align: center; margin-bottom: 20px; color: #1a365d; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { text-align: left; padding: 12px 14px; border-bottom: 1px solid #e2e8f0; }
        th { background-color: #2b6cb0; color: white; text-transform: uppercase; font-size: 13px; }
        tr:hover { background-color: #edf2f7; }
        .precio { font-weight: bold; color: #2e8540; }
        .vacio { text-align: center; font-style: italic; color: #718096; padding: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Reporte Detallado de Productos</h1>
        <table>
            <thead>
                <tr><th>ID</th><th>Nombre</th><th>Precio</th></tr>
            </thead>
            <tbody>
EOF

    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos;")

    if [[ "$cantidad" -gt 0 ]] 2>/dev/null; then
        local id nombre precio
        while IFS='|' read -r id nombre precio; do
            [[ -z "$id" ]] && continue
            cat <<EOF >> "$ARCH_REPORTE"
                <tr><td>$id</td><td>$nombre</td><td class="precio">\$$precio</td></tr>
EOF
        done < <(ejecutar_sql "SELECT id, nombre, precio FROM productos ORDER BY id;")
    else
        cat <<EOF >> "$ARCH_REPORTE"
                <tr><td colspan="3" class="vacio">No hay productos registrados en el sistema.</td></tr>
EOF
    fi

    cat <<EOF >> "$ARCH_REPORTE"
            </tbody>
        </table>
    </div>
</body>
</html>
EOF

    registrar_log "GENERAR_REPORTE_HTML"
    echo '{"ok":true,"mensaje":"Reporte generado con exito.","archivo":"productos.html"}'
}

rpc_logout() {
    local uid="$1"
    local uname="$2"
    SESION_USUARIO_ID="$uid"
    SESION_USUARIO_NOMBRE="$uname"
    registrar_log "CERRAR_SESION"
    echo '{"ok":true,"mensaje":"Sesion finalizada correctamente."}'
}

procesar_rpc() {
    local qs="$1"
    local accion
    local usuario
    local clave
    local id
    local nombre
    local precio
    local uid
    local uname

    accion=$(get_param "accion" "$qs")
    usuario=$(get_param "usuario" "$qs")
    clave=$(get_param "clave" "$qs")
    id=$(get_param "id" "$qs")
    nombre=$(get_param "nombre" "$qs")
    precio=$(get_param "precio" "$qs")
    uid=$(get_param "usuario_id" "$qs")
    uname=$(get_param "usuario_nombre" "$qs")

    case "$accion" in
        login) rpc_login "$usuario" "$clave" ;;
        registro) rpc_registro "$usuario" "$clave" ;;
        listar) rpc_listar "$uid" "$uname" ;;
        alta) rpc_alta "$id" "$nombre" "$precio" "$uid" "$uname" ;;
        baja) rpc_baja "$id" "$uid" "$uname" ;;
        editar) rpc_editar "$id" "$nombre" "$precio" "$uid" "$uname" ;;
        reporte_html) rpc_reporte_html "$uid" "$uname" ;;
        logout) rpc_logout "$uid" "$uname" ;;
        *) echo '{"ok":false,"error":"Accion RPC no reconocida."}' ;;
    esac
}

obtener_html() {
    cat << 'EOF'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sistema de Gestión - Web RPC</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        body { background-color: #f0f4f8; color: #1e293b; min-height: 100vh; display: flex; flex-direction: column; }
        header { background-color: #1e3a8a; color: #ffffff; padding: 16px 24px; display: flex; justify-content: space-between; align-items: center; }
        header h1 { font-size: 20px; font-weight: 600; }
        .user-nav { display: flex; align-items: center; gap: 12px; }
        .user-badge { background-color: #2563eb; padding: 6px 12px; border-radius: 20px; font-size: 13px; }
        .btn { padding: 8px 16px; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; border: none; }
        .btn-primary { background-color: #2563eb; color: white; }
        .btn-primary:hover { background-color: #1d4ed8; }
        .btn-danger { background-color: #dc2626; color: white; }
        .btn-danger:hover { background-color: #b91c1c; }
        .btn-secondary { background-color: #e2e8f0; color: #334155; }
        .btn-secondary:hover { background-color: #cbd5e1; }
        .btn-sm { padding: 4px 10px; font-size: 12px; }
        main { flex: 1; padding: 24px; max-width: 1000px; width: 100%; margin: 0 auto; }
        .alert { padding: 12px 16px; border-radius: 6px; margin-bottom: 20px; font-size: 14px; display: none; }
        .alert-success { background-color: #dcfce7; color: #15803d; border: 1px solid #bbf7d0; }
        .alert-error { background-color: #fee2e2; color: #b91c1c; border: 1px solid #fecaca; }
        .card { background: #ffffff; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); padding: 24px; margin-bottom: 24px; }
        .card-title { font-size: 17px; font-weight: 600; margin-bottom: 16px; color: #0f172a; display: flex; justify-content: space-between; align-items: center; }
        .form-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; }
        .form-group { display: flex; flex-direction: column; gap: 6px; }
        label { font-size: 13px; font-weight: 500; color: #475569; }
        input[type="text"], input[type="password"] { padding: 8px 12px; border: 1px solid #cbd5e1; border-radius: 6px; font-size: 14px; outline: none; }
        .form-actions { margin-top: 16px; display: flex; gap: 10px; }
        table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 12px; }
        th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid #e2e8f0; }
        th { background-color: #f8fafc; color: #475569; font-weight: 600; text-transform: uppercase; font-size: 12px; }
        .precio-col { font-weight: 600; color: #16a34a; }
        .empty-table { text-align: center; padding: 30px; color: #64748b; font-style: italic; }
        .auth-container { max-width: 440px; margin: 40px auto; }
        .auth-tabs { display: flex; border-bottom: 2px solid #e2e8f0; margin-bottom: 20px; }
        .auth-tab { flex: 1; padding: 10px; text-align: center; font-weight: 600; cursor: pointer; color: #64748b; }
        .auth-tab.active { color: #2563eb; border-bottom: 2px solid #2563eb; margin-bottom: -2px; }
    </style>
</head>
<body>
    <header>
        <h1>Sistema de Gestión (Web RPC)</h1>
        <div id="nav-user" class="user-nav" style="display: none;">
            <span class="user-badge" id="lbl-usuario">Usuario: -</span>
            <button class="btn btn-secondary btn-sm" onclick="generarReporteHTML()">Reporte HTML</button>
            <button class="btn btn-danger btn-sm" onclick="cerrarSesion()">Cerrar sesión</button>
        </div>
    </header>

    <main>
        <div id="alert-box" class="alert"></div>

        <div id="vista-auth" class="auth-container card">
            <div class="auth-tabs">
                <div id="tab-login" class="auth-tab active" onclick="cambiarTabAuth('login')">Iniciar Sesión</div>
                <div id="tab-registro" class="auth-tab" onclick="cambiarTabAuth('registro')">Registrar Usuario</div>
            </div>

            <form id="form-auth" onsubmit="procesarAuth(event)">
                <div class="form-group" style="margin-bottom: 14px;">
                    <label for="auth-usuario">Nombre de usuario</label>
                    <input type="text" id="auth-usuario" required autocomplete="username">
                </div>
                <div class="form-group" style="margin-bottom: 20px;">
                    <label for="auth-clave">Contraseña</label>
                    <input type="password" id="auth-clave" required autocomplete="current-password">
                </div>
                <button type="submit" id="btn-auth-submit" class="btn btn-primary" style="width: 100%;">Ingresar</button>
            </form>
        </div>

        <div id="vista-app" style="display: none;">
            <div class="card">
                <div class="card-title">
                    <span id="form-titulo">Alta de Producto</span>
                </div>
                <form id="form-producto" onsubmit="guardarProducto(event)">
                    <div class="form-grid">
                        <div class="form-group">
                            <label for="prod-id">ID del Producto</label>
                            <input type="text" id="prod-id" required>
                        </div>
                        <div class="form-group">
                            <label for="prod-nombre">Nombre</label>
                            <input type="text" id="prod-nombre" required>
                        </div>
                        <div class="form-group">
                            <label for="prod-precio">Precio</label>
                            <input type="text" id="prod-precio" required>
                        </div>
                    </div>
                    <div class="form-actions">
                        <button type="submit" class="btn btn-primary" id="btn-guardar">Guardar Producto</button>
                        <button type="button" class="btn btn-secondary" onclick="limpiarFormProducto()">Cancelar / Limpiar</button>
                    </div>
                </form>
            </div>

            <div class="card">
                <div class="card-title">
                    <span>Inventario de Productos</span>
                    <button class="btn btn-secondary btn-sm" onclick="cargarProductos()">Actualizar</button>
                </div>
                <div style="overflow-x: auto;">
                    <table>
                        <thead>
                            <tr>
                                <th>ID</th>
                                <th>Nombre</th>
                                <th>Precio</th>
                                <th style="text-align: right;">Acciones</th>
                            </tr>
                        </thead>
                        <tbody id="tabla-productos">
                            <tr>
                                <td colspan="4" class="empty-table">Cargando inventario...</td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </main>

    <script>
        let sesion = { id: null, nombre: null };
        let modoEdicion = false;
        let tabActual = 'login';

        function mostrarAlerta(mensaje, esError = false) {
            const box = document.getElementById('alert-box');
            box.className = 'alert ' + (esError ? 'alert-error' : 'alert-success');
            box.textContent = mensaje;
            box.style.display = 'block';
            setTimeout(() => { box.style.display = 'none'; }, 4000);
        }

        async function invocarRPC(params) {
            try {
                const body = new URLSearchParams(params).toString();
                const resp = await fetch('/rpc', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: body
                });
                return await resp.json();
            } catch (err) {
                return { ok: false, error: 'No se pudo conectar con el servidor: ' + err.message };
            }
        }

        function cambiarTabAuth(tab) {
            tabActual = tab;
            document.getElementById('tab-login').className = 'auth-tab ' + (tab === 'login' ? 'active' : '');
            document.getElementById('tab-registro').className = 'auth-tab ' + (tab === 'registro' ? 'active' : '');
            document.getElementById('btn-auth-submit').textContent = (tab === 'login' ? 'Ingresar' : 'Registrar Cuenta');
        }

        async function procesarAuth(e) {
            e.preventDefault();
            const usuario = document.getElementById('auth-usuario').value.trim();
            const clave = document.getElementById('auth-clave').value;

            if (tabActual === 'login') {
                const res = await invocarRPC({ accion: 'login', usuario: usuario, clave: clave });
                if (res.ok) {
                    sesion.id = res.usuario_id;
                    sesion.nombre = res.usuario_nombre;
                    document.getElementById('lbl-usuario').textContent = `Usuario: ${sesion.nombre} (ID: ${sesion.id})`;
                    document.getElementById('nav-user').style.display = 'flex';
                    document.getElementById('vista-auth').style.display = 'none';
                    document.getElementById('vista-app').style.display = 'block';
                    mostrarAlerta(`Bienvenido/a ${sesion.nombre}`);
                    cargarProductos();
                } else {
                    mostrarAlerta(res.error || 'Credenciales invalidas', true);
                }
            } else {
                const res = await invocarRPC({ accion: 'registro', usuario: usuario, clave: clave });
                if (res.ok) {
                    mostrarAlerta(res.mensaje || 'Usuario registrado exitosamente');
                    cambiarTabAuth('login');
                } else {
                    mostrarAlerta(res.error || 'No se pudo registrar el usuario', true);
                }
            }
        }

        async function cerrarSesion() {
            await invocarRPC({ accion: 'logout', usuario_id: sesion.id, usuario_nombre: sesion.nombre });
            sesion.id = null;
            sesion.nombre = null;
            document.getElementById('nav-user').style.display = 'none';
            document.getElementById('vista-app').style.display = 'none';
            document.getElementById('vista-auth').style.display = 'block';
            document.getElementById('form-auth').reset();
            mostrarAlerta('Sesión finalizada correctamente.');
        }

        async function cargarProductos() {
            const res = await invocarRPC({ accion: 'listar', usuario_id: sesion.id, usuario_nombre: sesion.nombre });
            const tbody = document.getElementById('tabla-productos');
            tbody.innerHTML = '';
            if (!res.ok || !res.productos || res.productos.length === 0) {
                tbody.innerHTML = '<tr><td colspan="4" class="empty-table">No hay productos registrados en el sistema.</td></tr>';
                return;
            }
            res.productos.forEach(prod => {
                const tr = document.createElement('tr');
                tr.innerHTML = `
                    <td><strong>${prod.id}</strong></td>
                    <td>${prod.nombre}</td>
                    <td class="precio-col">$${prod.precio}</td>
                    <td style="text-align: right;">
                        <button class="btn btn-secondary btn-sm" onclick="prepararEdicion('${prod.id}', '${encodeURIComponent(prod.nombre)}', '${prod.precio}')">Editar</button>
                        <button class="btn btn-danger btn-sm" onclick="eliminarProducto('${prod.id}', '${encodeURIComponent(prod.nombre)}')">Eliminar</button>
                    </td>
                `;
                tbody.appendChild(tr);
            });
        }

        function prepararEdicion(id, nombreEnc, precio) {
            modoEdicion = true;
            document.getElementById('form-titulo').textContent = `Editar Producto (ID: ${id})`;
            document.getElementById('prod-id').value = id;
            document.getElementById('prod-id').readOnly = true;
            document.getElementById('prod-nombre').value = decodeURIComponent(nombreEnc);
            document.getElementById('prod-precio').value = precio;
            document.getElementById('btn-guardar').textContent = 'Actualizar Cambios';
            window.scrollTo({ top: 0, behavior: 'smooth' });
        }

        function limpiarFormProducto() {
            modoEdicion = false;
            document.getElementById('form-titulo').textContent = 'Alta de Producto';
            document.getElementById('form-producto').reset();
            document.getElementById('prod-id').readOnly = false;
            document.getElementById('btn-guardar').textContent = 'Guardar Producto';
        }

        async function guardarProducto(e) {
            e.preventDefault();
            const id = document.getElementById('prod-id').value.trim();
            const nombre = document.getElementById('prod-nombre').value.trim();
            const precio = document.getElementById('prod-precio').value.trim();
            const accion = modoEdicion ? 'editar' : 'alta';

            const res = await invocarRPC({ accion: accion, id: id, nombre: nombre, precio: precio, usuario_id: sesion.id, usuario_nombre: sesion.nombre });
            if (res.ok) {
                mostrarAlerta(res.mensaje || 'Operación completada con éxito');
                limpiarFormProducto();
                cargarProductos();
            } else {
                mostrarAlerta(res.error || 'Error al procesar el producto', true);
            }
        }

        async function eliminarProducto(id, nombreEnc) {
            const nombre = decodeURIComponent(nombreEnc);
            if (!confirm(`¿Desea realmente eliminar el producto '${nombre}' (ID: ${id})?`)) return;
            const res = await invocarRPC({ accion: 'baja', id: id, usuario_id: sesion.id, usuario_nombre: sesion.nombre });
            if (res.ok) {
                mostrarAlerta(res.mensaje || 'Producto eliminado con éxito');
                cargarProductos();
            } else {
                mostrarAlerta(res.error || 'Error al eliminar el producto', true);
            }
        }

        async function generarReporteHTML() {
            const res = await invocarRPC({ accion: 'reporte_html', usuario_id: sesion.id, usuario_nombre: sesion.nombre });
            if (res.ok) {
                mostrarAlerta('Reporte generado exitosamente. Abriendo en una nueva pestaña...');
                window.open('/productos.html', '_blank');
            } else {
                mostrarAlerta(res.error || 'No se pudo generar el reporte HTML', true);
            }
        }
    </script>
</body>
</html>
EOF
}

procesar_http() {
    local metodo=""
    local ruta=""
    local protocolo=""

    read -r metodo ruta protocolo
    [[ -z "$metodo" ]] && return

    local content_length=0
    local linea=""
    while IFS= read -r linea; do
        linea="${linea%%$'\r'}"
        [[ -z "$linea" ]] && break
        if [[ "$linea" =~ [Cc]ontent-[Ll]ength:[[:space:]]*([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    local cuerpo=""
    if (( content_length > 0 )); then
        read -N "$content_length" cuerpo
    fi

    if [[ "$ruta" == "/rpc"* ]]; then
        local qs=""
        if [[ "$metodo" == "POST" ]]; then
            qs="$cuerpo"
        else
            qs="${ruta#*\?}"
        fi
        local res
        res=$(procesar_rpc "$qs")
        printf "HTTP/1.1 200 OK\r\n"
        printf "Content-Type: application/json; charset=utf-8\r\n"
        printf "Cache-Control: no-cache\r\n"
        printf "Content-Length: %s\r\n\r\n" "${#res}"
        printf "%s" "$res"
    elif [[ "$ruta" == "/productos.html" ]]; then
        if [[ -f "$ARCH_REPORTE" ]]; then
            local tam
            tam=$(wc -c < "$ARCH_REPORTE")
            printf "HTTP/1.1 200 OK\r\n"
            printf "Content-Type: text/html; charset=utf-8\r\n"
            printf "Content-Length: %s\r\n\r\n" "$tam"
            cat "$ARCH_REPORTE"
        else
            printf "HTTP/1.1 404 Not Found\r\n\r\nArchivo no encontrado"
        fi
    else
        local html
        html=$(obtener_html)
        printf "HTTP/1.1 200 OK\r\n"
        printf "Content-Type: text/html; charset=utf-8\r\n"
        printf "Content-Length: %s\r\n\r\n" "${#html}"
        printf "%s" "$html"
    fi
}

main() {
    inicializar_base_datos

    local fifo="/tmp/srv_fifo_$$"
    rm -f "$fifo"
    mkfifo "$fifo"
    trap 'rm -f "$fifo"; exit' INT TERM EXIT

    printf "=========================================================\n"
    printf "    SISTEMA DE GESTION - SERVIDOR WEB RPC (TP5)          \n"
    printf "=========================================================\n"
    printf "Servidor iniciado en el puerto %s...\n" "$PUERTO"
    printf "Abra su navegador en: http://localhost:%s\n" "$PUERTO"
    printf "Presione Ctrl + C para detener.\n"
    printf "=========================================================\n"

    local nc_cmd="nc -l -p $PUERTO"
    if ! nc -l -p "$PUERTO" < /dev/null 2>/dev/null; then
        nc_cmd="nc -l $PUERTO"
    fi

    while true; do
        cat "$fifo" | $nc_cmd | procesar_http > "$fifo"
    done
}

main

