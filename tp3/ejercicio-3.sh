#!/usr/bin/env bash

# ==============================================================================
# TP3 - Sistemas Operativos: ABM de Productos con SQLite3
#
# Reimplementación del TP2 reemplazando la persistencia en archivos TSV
# por una base de datos SQLite3 (data.sq3).
# Se conservan los mismos menúes y la misma experiencia de usuario.
# Se incorpora logging de acciones (system.log) y errores (error.log).
# Las contraseñas se almacenan cifradas con SHA256 (sha256sum).
# ==============================================================================

# --- Archivos del sistema ---
declare -r BASE_DATOS="data.sq3"
declare -r LOG_SISTEMA="system.log"
declare -r LOG_ERRORES="error.log"

# --- Variables de sesión (usuario autenticado) ---
SESION_USUARIO_ID=""
SESION_USUARIO_NOMBRE=""

# --- Códigos de opciones - Menú Inicial ---
declare -r -i OPCION_INI_LOGIN=1
declare -r -i OPCION_INI_REGISTRO=2
declare -r -i OPCION_INI_SALIR=3

# --- Códigos de opciones - Menú ABM ---
declare -r -i OPCION_ALTA=1
declare -r -i OPCION_BAJA=2
declare -r -i OPCION_EDITAR=3
declare -r -i OPCION_MOSTRAR=4
declare -r -i OPCION_HTML=5
declare -r -i OPCION_SALIR=6

# ==============================================================================
# Logging
# ==============================================================================

# Registra una acción del usuario en system.log
# Formato TSV: fecha_hora <TAB> id_usuario <TAB> nombre_usuario <TAB> acción
registrar_log() {
    local accion="$1"
    local fecha_hora
    fecha_hora=$(date "+%Y-%m-%d %H:%M:%S")
    local uid="${SESION_USUARIO_ID:--}"
    local uname="${SESION_USUARIO_NOMBRE:--}"
    printf "%s\t%s\t%s\t%s\n" "$fecha_hora" "$uid" "$uname" "$accion" >> "$LOG_SISTEMA"
}

# Registra un error en error.log
# Formato: fecha_hora <TAB> mensaje_de_error
registrar_error() {
    local mensaje="$1"
    local fecha_hora
    fecha_hora=$(date "+%Y-%m-%d %H:%M:%S")
    printf "%s\t%s\n" "$fecha_hora" "$mensaje" >> "$LOG_ERRORES"
}

# ==============================================================================
# Ejecución SQL con manejo de errores
# ==============================================================================

# Ejecuta una sentencia SQL contra la base de datos.
# Si ocurre un error, lo registra en error.log y retorna 1.
ejecutar_sql() {
    local sql="$1"
    local resultado
    local error_msg

    resultado=$(sqlite3 "$BASE_DATOS" "$sql" 2>&1)
    local codigo=$?

    if (( codigo != 0 )); then
        registrar_error "SQL Error: $resultado | Sentencia: $sql"
        printf "[Error]: Ocurrio un problema al acceder a la base de datos.\n" >&2
        return 1
    fi

    # Si la consulta devolvió resultados, los imprimimos
    [[ -n "$resultado" ]] && echo "$resultado"
    return 0
}

# ==============================================================================
# Punto 3 - Creación e inicialización de la base de datos
# ==============================================================================

# Chequea si existe data.sq3. Si no existe, crea el archivo y las tablas.
# Tablas:
#   usuarios(id INTEGER PK, nombre TEXT UNIQUE, hash_clave TEXT)
#   productos(id TEXT PK, nombre TEXT, precio TEXT)
inicializar_base_datos() {
    if [[ -f "$BASE_DATOS" ]]; then
        return 0
    fi

    printf "Inicializando base de datos '%s'...\n" "$BASE_DATOS"

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

    if ! ejecutar_sql "$sql_creacion"; then
        registrar_error "No se pudo inicializar la base de datos."
        printf "[Error critico]: No se pudo crear la base de datos. Abortando.\n" >&2
        exit 1
    fi

    printf "Base de datos inicializada correctamente.\n"
}

# ==============================================================================
# Seguridad y Autenticación (SHA256 + SQLite3)
# ==============================================================================

# Calcula el hash SHA256 de una cadena de texto
calcular_hash() {
    local clave="$1"
    local hash_raw
    hash_raw=$(echo -n "$clave" | sha256sum)
    # sha256sum retorna: <hash_64_caracteres>  -
    # Extraemos solo los 64 caracteres del hash mediante subcadena
    local hash_limpio="${hash_raw:0:64}"
    echo "$hash_limpio"
}

# Verifica si un usuario ya existe en la base de datos
usuario_existe() {
    local usuario_buscado="$1"
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM usuarios WHERE nombre = '$usuario_buscado';")
    [[ "$cantidad" -gt 0 ]] 2>/dev/null && return 0
    return 1
}

# Registra un nuevo usuario con contraseña cifrada en SHA256.
# Valida que el usuario no exista previamente.
registrar_usuario() {
    local usuario=""
    local clave=""

    printf "\n--- REGISTRAR NUEVO USUARIO ---\n"
    read -rp "Ingrese nombre de usuario: " usuario

    if [[ -z "$usuario" ]]; then
        printf "[Error]: El nombre de usuario no puede estar vacio.\n" >&2
        registrar_error "Registro fallido: nombre de usuario vacio."
        return 1
    fi

    # Validación: no agregar un usuario ya existente
    if usuario_existe "$usuario"; then
        printf "[Error]: El usuario '%s' ya se encuentra registrado.\n" "$usuario" >&2
        registrar_error "Registro fallido: usuario '$usuario' ya existe."
        return 1
    fi

    read -rsp "Ingrese contrasena: " clave
    printf "\n"

    if [[ -z "$clave" ]]; then
        printf "[Error]: La contrasena no puede estar vacia.\n" >&2
        registrar_error "Registro fallido: contrasena vacia para usuario '$usuario'."
        return 1
    fi

    # Cifrar la contraseña con SHA256 antes de guardarla
    local hash_clave
    hash_clave=$(calcular_hash "$clave")

    if ! ejecutar_sql "INSERT INTO usuarios (nombre, hash_clave) VALUES ('$usuario', '$hash_clave');"; then
        registrar_error "Registro fallido: error SQL al insertar usuario '$usuario'."
        return 1
    fi

    printf "Usuario '%s' registrado exitosamente.\n" "$usuario"
    registrar_log "REGISTRO_USUARIO: $usuario"
    return 0
}

# Inicio de sesión con 3 intentos máximos.
# Compara el hash SHA256 del input contra el almacenado en la BD.
# Si es exitoso, guarda el ID y nombre del usuario en variables de sesión.
iniciar_sesion() {
    local intentos=0
    local usuario=""
    local clave=""

    printf "\n--- INICIO DE SESION ---\n"

    while (( intentos < 3 )); do
        read -rp "Usuario: " usuario
        read -rsp "Contrasena: " clave
        printf "\n"

        # Cifrar la contraseña ingresada para comparar
        local hash_ingresado
        hash_ingresado=$(calcular_hash "$clave")

        # Buscar en la BD un usuario que coincida en nombre y hash
        local resultado
        resultado=$(ejecutar_sql "SELECT id, nombre FROM usuarios WHERE nombre = '$usuario' AND hash_clave = '$hash_ingresado';")

        if [[ -n "$resultado" ]]; then
            # SQLite devuelve id|nombre por defecto (separado por |)
            SESION_USUARIO_ID=$(echo "$resultado" | cut -d'|' -f1)
            SESION_USUARIO_NOMBRE=$(echo "$resultado" | cut -d'|' -f2)
            printf "Acceso concedido. Bienvenido/a %s.\n" "$SESION_USUARIO_NOMBRE"
            registrar_log "INICIO_SESION"
            return 0
        fi

        intentos=$((intentos + 1))
        printf "Credenciales incorrectas (%d/3 intentos).\n" "$intentos"
    done

    printf "[Error]: Se supero el maximo de intentos permitidos.\n" >&2
    registrar_error "Login fallido: maximo de intentos superado para usuario '$usuario'."
    registrar_log "LOGIN_FALLIDO: $usuario"
    return 1
}

# ==============================================================================
# Gestión de Productos (SQLite3)
# ==============================================================================

# Verifica si un producto con el ID dado ya existe en la BD
producto_existe() {
    local id_buscado="$1"
    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos WHERE id = '$id_buscado';")
    [[ "$cantidad" -gt 0 ]] 2>/dev/null && return 0
    return 1
}

# Alta de producto: solicita ID, nombre y precio.
# Valida que no exista un producto con el mismo ID.
alta_producto() {
    local id=""
    local nombre=""
    local precio=""

    printf "\n--- ALTA DE PRODUCTO ---\n"
    read -rp "Ingrese ID: " id

    if [[ -z "$id" ]]; then
        printf "[Error]: El ID no puede estar vacio.\n" >&2
        registrar_error "Alta fallida: ID vacio."
        return 1
    fi

    # Validación: no agregar un producto ya existente
    if producto_existe "$id"; then
        printf "[Error]: Ya existe un producto con el ID '%s'. Operacion cancelada.\n" "$id" >&2
        registrar_error "Alta fallida: producto con ID '$id' ya existe."
        return 1
    fi

    read -rp "Ingrese Nombre: " nombre
    if [[ -z "$nombre" ]]; then
        printf "[Error]: El nombre no puede estar vacio.\n" >&2
        registrar_error "Alta fallida: nombre vacio para ID '$id'."
        return 1
    fi

    read -rp "Ingrese Precio: " precio
    if [[ -z "$precio" ]]; then
        printf "[Error]: El precio no puede estar vacio.\n" >&2
        registrar_error "Alta fallida: precio vacio para ID '$id'."
        return 1
    fi

    if ! ejecutar_sql "INSERT INTO productos (id, nombre, precio) VALUES ('$id', '$nombre', '$precio');"; then
        registrar_error "Alta fallida: error SQL al insertar producto ID '$id'."
        return 1
    fi

    printf "Producto '%s' (ID: %s) guardado con precio $%s.\n" "$nombre" "$id" "$precio"
    registrar_log "ALTA_PRODUCTO: ID=$id, Nombre=$nombre, Precio=$precio"
    return 0
}

# Baja de producto: elimina el producto cuyo ID coincide.
baja_producto() {
    local id=""

    printf "\n--- BAJA DE PRODUCTO ---\n"
    read -rp "Ingrese ID a eliminar: " id

    if ! producto_existe "$id"; then
        printf "[Error]: El producto con ID '%s' no existe.\n" "$id" >&2
        registrar_error "Baja fallida: producto con ID '$id' no existe."
        return 1
    fi

    if ! ejecutar_sql "DELETE FROM productos WHERE id = '$id';"; then
        registrar_error "Baja fallida: error SQL al eliminar producto ID '$id'."
        return 1
    fi

    printf "Producto con ID '%s' eliminado correctamente.\n" "$id"
    registrar_log "BAJA_PRODUCTO: ID=$id"
    return 0
}

# Editar producto: modifica el nombre y precio de un producto existente.
editar_producto() {
    local id=""

    printf "\n--- EDITAR PRODUCTO ---\n"
    read -rp "Ingrese ID del producto a modificar: " id

    if ! producto_existe "$id"; then
        printf "[Error]: El producto con ID '%s' no existe.\n" "$id" >&2
        registrar_error "Edicion fallida: producto con ID '$id' no existe."
        return 1
    fi

    local nuevo_nombre=""
    local nuevo_precio=""

    read -rp "Ingrese nuevo Nombre: " nuevo_nombre
    read -rp "Ingrese nuevo Precio: " nuevo_precio

    if [[ -z "$nuevo_nombre" || -z "$nuevo_precio" ]]; then
        printf "[Error]: El nombre y precio no pueden estar vacios.\n" >&2
        registrar_error "Edicion fallida: nombre o precio vacio para producto ID '$id'."
        return 1
    fi

    if ! ejecutar_sql "UPDATE productos SET nombre = '$nuevo_nombre', precio = '$nuevo_precio' WHERE id = '$id';"; then
        registrar_error "Edicion fallida: error SQL al actualizar producto ID '$id'."
        return 1
    fi

    printf "Producto con ID '%s' modificado exitosamente.\n" "$id"
    registrar_log "EDITAR_PRODUCTO: ID=$id, NuevoNombre=$nuevo_nombre, NuevoPrecio=$nuevo_precio"
    return 0
}

# Muestra el inventario completo leyendo desde la BD.
mostrar_inventario() {
    printf "\n--- INVENTARIO DE PRODUCTOS ---\n"

    local cantidad
    cantidad=$(ejecutar_sql "SELECT COUNT(*) FROM productos;")

    if [[ "$cantidad" -eq 0 ]] 2>/dev/null; then
        printf "No hay productos registrados.\n"
        registrar_log "MOSTRAR_INVENTARIO: sin productos"
        return 0
    fi

    printf "%-8s | %-25s | %-12s\n" "ID" "NOMBRE" "PRECIO"
    printf "%s\n" "----------------------------------------------------"

    # Usamos el separador de columnas TAB para leer la salida de SQLite
    local id nombre precio
    while IFS=$'|' read -r id nombre precio; do
        [[ -z "$id" ]] && continue
        printf "%-8s | %-25s | \$%-12s\n" "$id" "$nombre" "$precio"
    done < <(ejecutar_sql "SELECT id, nombre, precio FROM productos ORDER BY id;")

    registrar_log "MOSTRAR_INVENTARIO"
}

# ==============================================================================
# Generación de Reporte HTML (productos.html)
# ==============================================================================
generar_reporte_html() {
    local salida="productos.html"
    printf "\nGenerando reporte en '%s'...\n" "$salida"

    # Cabecera del HTML con estilos
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

    # Cuerpo de la tabla: leer productos desde la BD
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

    # Cierre del HTML
    cat <<EOF >> "$salida"
            </tbody>
        </table>
    </div>
</body>
</html>
EOF

    printf "Reporte generado con exito. Puede abrir '%s' en su navegador.\n" "$salida"
    registrar_log "GENERAR_REPORTE_HTML"
}

# ==============================================================================
# Menú Principal de Productos (tras autenticación exitosa)
# ==============================================================================
menu_productos() {
    local opcion=0

    while [[ "$opcion" != "$OPCION_SALIR" ]]; do
        printf "\n=====================================\n"
        printf "       MENU GESTION DE PRODUCTOS     \n"
        printf "=====================================\n"
        printf "1. Alta producto\n"
        printf "2. Baja producto\n"
        printf "3. Editar producto\n"
        printf "4. Mostrar inventario\n"
        printf "5. Generar reporte HTML\n"
        printf "6. Cerrar sesion\n"
        printf "=====================================\n"
        read -rp "Seleccione una opcion: " opcion

        case $opcion in
            $OPCION_ALTA)
                alta_producto
                ;;
            $OPCION_BAJA)
                baja_producto
                ;;
            $OPCION_EDITAR)
                editar_producto
                ;;
            $OPCION_MOSTRAR)
                mostrar_inventario
                ;;
            $OPCION_HTML)
                generar_reporte_html
                ;;
            $OPCION_SALIR)
                printf "\nCerrando sesion de usuario...\n"
                registrar_log "CERRAR_SESION"
                # Limpiar variables de sesión
                SESION_USUARIO_ID=""
                SESION_USUARIO_NOMBRE=""
                ;;
            *)
                printf "\nOpcion invalida. Intente nuevamente.\n"
                ;;
        esac
    done
}

# ==============================================================================
# Menú de Entrada: Iniciar Sesión / Registrar Usuario
# ==============================================================================
menu_inicio() {
    local opcion=0

    while [[ "$opcion" != "$OPCION_INI_SALIR" ]]; do
        printf "\n=====================================\n"
        printf "    SISTEMA DE GESTION - BIENVENIDO  \n"
        printf "=====================================\n"
        printf "1. Iniciar sesion\n"
        printf "2. Registrar usuario\n"
        printf "3. Salir\n"
        printf "=====================================\n"
        read -rp "Seleccione una opcion: " opcion

        case $opcion in
            $OPCION_INI_LOGIN)
                if iniciar_sesion; then
                    menu_productos
                fi
                ;;
            $OPCION_INI_REGISTRO)
                registrar_usuario
                ;;
            $OPCION_INI_SALIR)
                printf "\nGracias por utilizar el sistema. Hasta luego!\n"
                registrar_log "SALIR_SISTEMA"
                ;;
            *)
                printf "\nOpcion invalida. Intente nuevamente.\n"
                ;;
        esac
    done
}

# ==============================================================================
# Punto de Entrada
# ==============================================================================
main() {
    # Punto 3: chequear si existe data.sq3, si no, crearlo con las tablas
    inicializar_base_datos
        menu_inicio
    return 0
}

main

