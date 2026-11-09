#!/usr/bin/env bash

declare -r BASE_DATOS="data.sq3"
declare -r LOG_SISTEMA="system.log"
declare -r LOG_ERRORES="error.log"

SESION_USUARIO_ID=""
SESION_USUARIO_NOMBRE=""

if command -v whiptail &>/dev/null; then
    TUI_BIN="whiptail"
elif command -v dialog &>/dev/null; then
    TUI_BIN="dialog"
else
    printf "Error: se requiere 'whiptail' o 'dialog' para la interfaz TUI.\n" >&2
    printf "Instalelo ejecutando: sudo apt install -y whiptail\n" >&2
    exit 1
fi

tui_msgbox() {
    local titulo="$1"
    local mensaje="$2"
    "$TUI_BIN" --title "$titulo" --msgbox "$mensaje" 10 55
}

tui_yesno() {
    local titulo="$1"
    local mensaje="$2"
    "$TUI_BIN" --title "$titulo" --yesno "$mensaje" 10 55
}

tui_inputbox() {
    local titulo="$1"
    local mensaje="$2"
    local default="${3:-}"
    "$TUI_BIN" --title "$titulo" --inputbox "$mensaje" 10 55 "$default" 3>&1 1>&2 2>&3
}

tui_passwordbox() {
    local titulo="$1"
    local mensaje="$2"
    "$TUI_BIN" --title "$titulo" --passwordbox "$mensaje" 10 55 3>&1 1>&2 2>&3
}

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
        tui_msgbox "Error de Base de Datos" "Ocurrio un problema al acceder a la base de datos."
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

    if ! sqlite3 "$BASE_DATOS" "$sql_creacion" 2>/dev/null; then
        registrar_error "No se pudo inicializar la base de datos."
        printf "Error critico: no se pudo crear la base de datos.\n" >&2
        exit 1
    fi
}

calcular_hash() {
    local clave="$1"
    local hash_raw
    hash_raw=$(echo -n "$clave" | sha256sum)
    local hash_limpio="${hash_raw:0:64}"
    echo "$hash_limpio"
}

usuario_existe() {
    local usuario_buscado="$1"
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM usuarios WHERE nombre = '$usuario_buscado';")
    [[ "$cantidad" -gt 0 ]] 2>/dev/null && return 0
    return 1
}

registrar_usuario() {
    local usuario=""
    local clave=""

    usuario=$(tui_inputbox "Registro de Usuario" "Ingrese nombre de usuario:")
    [[ $? -ne 0 ]] && return 1

    if [[ -z "$usuario" ]]; then
        tui_msgbox "Error" "El nombre de usuario no puede estar vacio."
        registrar_error "Registro fallido: nombre de usuario vacio."
        return 1
    fi

    if usuario_existe "$usuario"; then
        tui_msgbox "Error" "El usuario '$usuario' ya se encuentra registrado."
        registrar_error "Registro fallido: usuario '$usuario' ya existe."
        return 1
    fi

    clave=$(tui_passwordbox "Registro de Usuario" "Ingrese contrasena:")
    [[ $? -ne 0 ]] && return 1

    if [[ -z "$clave" ]]; then
        tui_msgbox "Error" "La contrasena no puede estar vacia."
        registrar_error "Registro fallido: contrasena vacia para usuario '$usuario'."
        return 1
    fi

    local hash_clave
    hash_clave=$(calcular_hash "$clave")

    if ! ejecutar_sql "INSERT INTO usuarios (nombre, hash_clave) VALUES ('$usuario', '$hash_clave');"; then
        registrar_error "Registro fallido: error SQL al insertar usuario '$usuario'."
        return 1
    fi

    tui_msgbox "Exito" "Usuario '$usuario' registrado exitosamente."
    registrar_log "REGISTRO_USUARIO: $usuario"
    return 0
}

iniciar_sesion() {
    local intentos=0
    local usuario=""
    local clave=""

    while (( intentos < 3 )); do
        usuario=$(tui_inputbox "Inicio de Sesion" "Ingrese nombre de usuario:" "$usuario")
        [[ $? -ne 0 ]] && return 1

        clave=$(tui_passwordbox "Inicio de Sesion" "Ingrese contrasena:")
        [[ $? -ne 0 ]] && return 1

        local hash_ingresado
        hash_ingresado=$(calcular_hash "$clave")

        local resultado
        resultado=$(ejecutar_sql "SELECT id, nombre FROM usuarios WHERE nombre = '$usuario' AND hash_clave = '$hash_ingresado';")

        if [[ -n "$resultado" ]]; then
            SESION_USUARIO_ID=$(echo "$resultado" | cut -d'|' -f1)
            SESION_USUARIO_NOMBRE=$(echo "$resultado" | cut -d'|' -f2)
            tui_msgbox "Bienvenido" "Acceso concedido. Bienvenido/a $SESION_USUARIO_NOMBRE."
            registrar_log "INICIO_SESION"
            return 0
        fi

        intentos=$((intentos + 1))
        tui_msgbox "Error de Autenticacion" "Credenciales incorrectas ($intentos/3 intentos)."
    done

    registrar_error "Login fallido: maximo de intentos superado para usuario '$usuario'."
    registrar_log "LOGIN_FALLIDO: $usuario"
    tui_msgbox "Acceso Denegado" "Se supero el maximo de intentos permitidos."
    return 1
}

producto_existe() {
    local id_buscado="$1"
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos WHERE id = '$id_buscado';")
    [[ "$cantidad" -gt 0 ]] 2>/dev/null && return 0
    return 1
}

alta_producto() {
    local id=""
    local nombre=""
    local precio=""

    id=$(tui_inputbox "Alta de Producto" "Ingrese ID:")
    [[ $? -ne 0 ]] && return 1

    if [[ -z "$id" ]]; then
        tui_msgbox "Error" "El ID no puede estar vacio."
        registrar_error "Alta fallida: ID vacio."
        return 1
    fi

    if producto_existe "$id"; then
        tui_msgbox "Error" "Ya existe un producto con el ID '$id'. Operacion cancelada."
        registrar_error "Alta fallida: producto con ID '$id' ya existe."
        return 1
    fi

    nombre=$(tui_inputbox "Alta de Producto" "Ingrese Nombre:")
    [[ $? -ne 0 ]] && return 1

    if [[ -z "$nombre" ]]; then
        tui_msgbox "Error" "El nombre no puede estar vacio."
        registrar_error "Alta fallida: nombre vacio para ID '$id'."
        return 1
    fi

    precio=$(tui_inputbox "Alta de Producto" "Ingrese Precio:")
    [[ $? -ne 0 ]] && return 1

    if [[ -z "$precio" ]]; then
        tui_msgbox "Error" "El precio no puede estar vacio."
        registrar_error "Alta fallida: precio vacio para ID '$id'."
        return 1
    fi

    if ! ejecutar_sql "INSERT INTO productos (id, nombre, precio) VALUES ('$id', '$nombre', '$precio');"; then
        registrar_error "Alta fallida: error SQL al insertar producto ID '$id'."
        return 1
    fi

    tui_msgbox "Exito" "Producto '$nombre' (ID: $id) guardado con precio \$$precio."
    registrar_log "ALTA_PRODUCTO: ID=$id, Nombre=$nombre, Precio=$precio"
    return 0
}

baja_producto() {
    local id=""

    id=$(tui_inputbox "Baja de Producto" "Ingrese ID a eliminar:")
    [[ $? -ne 0 ]] && return 1

    if ! producto_existe "$id"; then
        tui_msgbox "Error" "El producto con ID '$id' no existe."
        registrar_error "Baja fallida: producto con ID '$id' no existe."
        return 1
    fi

    local datos_prod
    datos_prod=$(ejecutar_sql "SELECT nombre FROM productos WHERE id = '$id';")

    if ! tui_yesno "Confirmar Baja" "Desea realmente eliminar el producto '$datos_prod' (ID: $id)?"; then
        return 0
    fi

    if ! ejecutar_sql "DELETE FROM productos WHERE id = '$id';"; then
        registrar_error "Baja fallida: error SQL al eliminar producto ID '$id'."
        return 1
    fi

    tui_msgbox "Exito" "Producto con ID '$id' eliminado correctamente."
    registrar_log "BAJA_PRODUCTO: ID=$id"
    return 0
}

editar_producto() {
    local id=""

    id=$(tui_inputbox "Editar Producto" "Ingrese ID del producto a modificar:")
    [[ $? -ne 0 ]] && return 1

    if ! producto_existe "$id"; then
        tui_msgbox "Error" "El producto con ID '$id' no existe."
        registrar_error "Edicion fallida: producto con ID '$id' no existe."
        return 1
    fi

    local datos_actuales
    datos_actuales=$(ejecutar_sql "SELECT nombre, precio FROM productos WHERE id = '$id';")
    local nom_act
    local pre_act
    nom_act=$(echo "$datos_actuales" | cut -d'|' -f1)
    pre_act=$(echo "$datos_actuales" | cut -d'|' -f2)

    local nuevo_nombre
    nuevo_nombre=$(tui_inputbox "Editar Producto" "Ingrese nuevo Nombre:" "$nom_act")
    [[ $? -ne 0 ]] && return 1

    local nuevo_precio
    nuevo_precio=$(tui_inputbox "Editar Producto" "Ingrese nuevo Precio:" "$pre_act")
    [[ $? -ne 0 ]] && return 1

    if [[ -z "$nuevo_nombre" || -z "$nuevo_precio" ]]; then
        tui_msgbox "Error" "El nombre y precio no pueden estar vacios."
        registrar_error "Edicion fallida: nombre o precio vacio para producto ID '$id'."
        return 1
    fi

    if ! ejecutar_sql "UPDATE productos SET nombre = '$nuevo_nombre', precio = '$nuevo_precio' WHERE id = '$id';"; then
        registrar_error "Edicion fallida: error SQL al actualizar producto ID '$id'."
        return 1
    fi

    tui_msgbox "Exito" "Producto con ID '$id' modificado exitosamente."
    registrar_log "EDITAR_PRODUCTO: ID=$id, NuevoNombre=$nuevo_nombre, NuevoPrecio=$nuevo_precio"
    return 0
}

mostrar_inventario() {
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos;")

    if [[ "$cantidad" -eq 0 ]] 2>/dev/null; then
        tui_msgbox "Inventario" "No hay productos registrados en el sistema."
        registrar_log "MOSTRAR_INVENTARIO: sin productos"
        return 0
    fi

    local arch_temp
    arch_temp=$(mktemp)

    printf "%-10s | %-32s | %-12s\n" "ID" "NOMBRE" "PRECIO" >> "$arch_temp"
    printf "%s\n" "------------------------------------------------------------------" >> "$arch_temp"

    local id nombre precio
    while IFS=$'|' read -r id nombre precio; do
        [[ -z "$id" ]] && continue
        printf "%-10s | %-32s | \$%-12s\n" "$id" "$nombre" "$precio" >> "$arch_temp"
    done < <(ejecutar_sql "SELECT id, nombre, precio FROM productos ORDER BY id;")

    "$TUI_BIN" --title "Inventario de Productos" --textbox "$arch_temp" 20 70
    rm -f "$arch_temp"
    registrar_log "MOSTRAR_INVENTARIO"
}

generar_reporte_html() {
    local salida="productos.html"

    cat <<EOF > "$salida"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Reporte de Productos</title>
    <style>
        body {
            font-family: Arial, Helvetica, sans-serif;
            background-color: #f7f9fc;
            color: #2c3e50;
            margin: 0;
            padding: 30px;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: #ffffff;
            border-radius: 8px;
            padding: 24px;
            box-shadow: 0 4px 10px rgba(0, 0, 0, 0.08);
        }
        h1 {
            text-align: center;
            margin-bottom: 20px;
            color: #1a365d;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        th, td {
            text-align: left;
            padding: 12px 14px;
            border-bottom: 1px solid #e2e8f0;
        }
        th {
            background-color: #2b6cb0;
            color: white;
            text-transform: uppercase;
            font-size: 13px;
            letter-spacing: 0.05em;
        }
        tr:hover {
            background-color: #edf2f7;
        }
        .precio {
            font-weight: bold;
            color: #2e8540;
        }
        .vacio {
            text-align: center;
            font-style: italic;
            color: #718096;
            padding: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Reporte Detallado de Productos</h1>
        <table>
            <thead>
                <tr>
                    <th>ID</th>
                    <th>Nombre</th>
                    <th>Precio</th>
                </tr>
            </thead>
            <tbody>
EOF

    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos;")

    if [[ "$cantidad" -gt 0 ]] 2>/dev/null; then
        local id nombre precio
        while IFS='|' read -r id nombre precio; do
            [[ -z "$id" ]] && continue
            cat <<EOF >> "$salida"
                <tr>
                    <td>$id</td>
                    <td>$nombre</td>
                    <td class="precio">\$$precio</td>
                </tr>
EOF
        done < <(ejecutar_sql "SELECT id, nombre, precio FROM productos ORDER BY id;")
    else
        cat <<EOF >> "$salida"
                <tr>
                    <td colspan="3" class="vacio">No hay productos registrados en el sistema.</td>
                </tr>
EOF
    fi

    cat <<EOF >> "$salida"
            </tbody>
        </table>
    </div>
</body>
</html>
EOF

    tui_msgbox "Reporte Generado" "Reporte generado con exito en '$salida'. Puede abrirlo en su navegador."
    registrar_log "GENERAR_REPORTE_HTML"
}

menu_productos() {
    local opcion=""

    while true; do
        opcion=$("$TUI_BIN" --title "MENU GESTION DE PRODUCTOS ($SESION_USUARIO_NOMBRE)" \
            --menu "Seleccione una operacion:" 17 60 6 \
            "1" "Alta producto" \
            "2" "Baja producto" \
            "3" "Editar producto" \
            "4" "Mostrar inventario" \
            "5" "Generar reporte HTML" \
            "6" "Cerrar sesion" \
            3>&1 1>&2 2>&3)

        local estado=$?
        if (( estado != 0 )) || [[ "$opcion" == "6" ]]; then
            registrar_log "CERRAR_SESION"
            SESION_USUARIO_ID=""
            SESION_USUARIO_NOMBRE=""
            break
        fi

        case "$opcion" in
            1) alta_producto ;;
            2) baja_producto ;;
            3) editar_producto ;;
            4) mostrar_inventario ;;
            5) generar_reporte_html ;;
        esac
    done
}

menu_inicio() {
    local opcion=""

    while true; do
        opcion=$("$TUI_BIN" --title "SISTEMA DE GESTION - TUI" \
            --menu "Seleccione una opcion:" 14 55 3 \
            "1" "Iniciar sesion" \
            "2" "Registrar usuario" \
            "3" "Salir" \
            3>&1 1>&2 2>&3)

        local estado=$?
        if (( estado != 0 )) || [[ "$opcion" == "3" ]]; then
            registrar_log "SALIR_SISTEMA"
            clear
            break
        fi

        case "$opcion" in
            1)
                if iniciar_sesion; then
                    menu_productos
                fi
                ;;
            2)
                registrar_usuario
                ;;
        esac
    done
}

main() {
    inicializar_base_datos
    menu_inicio
    return 0
}

main

