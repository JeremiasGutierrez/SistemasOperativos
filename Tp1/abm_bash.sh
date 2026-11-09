#!/usr/bin/env bash

# ==============================================================================
# TP1 - Sistemas Operativos: ABM de Productos y Autenticación en Bash
# ==============================================================================

# Archivos de persistencia
declare -r ARCH_PRODUCTOS="productos.tsv"
declare -r ARCH_USUARIOS="usuarios.tsv"

# Códigos de opciones - Menú Inicial
declare -r -i OPCION_INI_LOGIN=1
declare -r -i OPCION_INI_REGISTRO=2
declare -r -i OPCION_INI_SALIR=3

# Códigos de opciones - Menú ABM
declare -r -i OPCION_ALTA=1
declare -r -i OPCION_BAJA=2
declare -r -i OPCION_EDITAR=3
declare -r -i OPCION_MOSTRAR=4
declare -r -i OPCION_HTML=5
declare -r -i OPCION_SALIR=6

# ------------------------------------------------------------------------------
# Inicialización de entorno
# ------------------------------------------------------------------------------
inicializar_archivos() {
    # Aseguramos que los archivos TSV existan para evitar errores de lectura
    [[ ! -f "$ARCH_PRODUCTOS" ]] && touch "$ARCH_PRODUCTOS"
    [[ ! -f "$ARCH_USUARIOS" ]] && touch "$ARCH_USUARIOS"
}

# ------------------------------------------------------------------------------
# Seguridad y Autenticación
# ------------------------------------------------------------------------------
calcular_hash() {
    local clave="$1"
    # echo -n evita el salto de línea al final
    local hash_raw
    hash_raw=$(echo -n "$clave" | sha256sum)
    # sha256sum retorna el hash de 64 caracteres seguido de '  -'
    # Extraemos solo los 64 caracteres del hash hexadecimal usando subcadena
    echo "${hash_raw:0:64}"
}

usuario_existe() {
    local usuario_buscado="$1"
    [[ ! -f "$ARCH_USUARIOS" ]] && return 1

    local usuario hash
    while IFS=$'\t' read -r usuario hash; do
        if [[ "$usuario" == "$usuario_buscado" ]]; then
            return 0
        fi
    done < "$ARCH_USUARIOS"

    return 1
}

registrar_usuario() {
    local usuario=""
    local clave=""

    printf "\n--- REGISTRAR NUEVO USUARIO ---\n"
    read -rp "Ingrese nombre de usuario: " usuario

    if [[ -z "$usuario" ]]; then
        printf "[Error en registrar_usuario]: El nombre de usuario no puede estar vacio.\n" >&2
        return 1
    fi

    if usuario_existe "$usuario"; then
        printf "[Error en registrar_usuario]: El usuario '%s' ya se encuentra registrado.\n" "$usuario" >&2
        return 1
    fi

    read -rsp "Ingrese contrasena: " clave
    printf "\n"

    if [[ -z "$clave" ]]; then
        printf "[Error en registrar_usuario]: La contrasena no puede estar vacia.\n" >&2
        return 1
    fi

    local hash_clave
    hash_clave=$(calcular_hash "$clave")

    # Guardar en usuarios.tsv en formato TSV (Usuario<TAB>Hash)
    printf "%s\t%s\n" "$usuario" "$hash_clave" >> "$ARCH_USUARIOS"
    printf "Usuario '%s' registrado exitosamente.\n" "$usuario"
    return 0
}

iniciar_sesion() {
    local intentos=0
    local usuario=""
    local clave=""

    printf "\n--- INICIO DE SESION ---\n"

    while (( intentos < 3 )); do
        read -rp "Usuario: " usuario
        read -rsp "Contrasena: " clave
        printf "\n"

        local hash_ingresado
        hash_ingresado=$(calcular_hash "$clave")

        local u h encontrado=0
        if [[ -f "$ARCH_USUARIOS" ]]; then
            while IFS=$'\t' read -r u h; do
                if [[ "$u" == "$usuario" && "$h" == "$hash_ingresado" ]]; then
                    encontrado=1
                    break
                fi
            done < "$ARCH_USUARIOS"
        fi

        if (( encontrado == 1 )); then
            printf "Acceso concedido. Bienvenido/a %s.\n" "$usuario"
            return 0
        fi

        intentos=$((intentos + 1))
        printf "Credenciales incorrectas (%d/3 intentos).\n" "$intentos"
    done

    printf "[Error en iniciar_sesion]: Se supero el maximo de intentos permitidos para el usuario '%s'.\n" "$usuario" >&2
    return 1
}

# ------------------------------------------------------------------------------
# Gestión de Productos (Persistencia en TSV)
# ------------------------------------------------------------------------------
producto_existe() {
    local id_buscado="$1"
    [[ ! -f "$ARCH_PRODUCTOS" ]] && return 1

    local id nombre precio
    while IFS=$'\t' read -r id nombre precio; do
        if [[ "$id" == "$id_buscado" ]]; then
            return 0
        fi
    done < "$ARCH_PRODUCTOS"

    return 1
}

alta_producto() {
    local id=""
    local nombre=""
    local precio=""

    printf "\n--- ALTA DE PRODUCTO ---\n"
    read -rp "Ingrese ID: " id

    if [[ -z "$id" ]]; then
        printf "[Error en alta_producto]: El ID no puede estar vacio.\n" >&2
        return 1
    fi

    if producto_existe "$id"; then
        printf "[Error en alta_producto]: Ya existe un producto con el ID '%s'. Operacion cancelada.\n" "$id" >&2
        return 1
    fi

    read -rp "Ingrese Nombre: " nombre
    if [[ -z "$nombre" ]]; then
        printf "[Error en alta_producto]: El nombre no puede estar vacio.\n" >&2
        return 1
    fi

    read -rp "Ingrese Precio: " precio
    if [[ -z "$precio" ]]; then
        printf "[Error en alta_producto]: El precio no puede estar vacio.\n" >&2
        return 1
    fi

    # Guardar en productos.tsv (ID<TAB>Nombre<TAB>Precio)
    printf "%s\t%s\t%s\n" "$id" "$nombre" "$precio" >> "$ARCH_PRODUCTOS"
    printf "Producto '%s' (ID: %s) guardado con precio $%s.\n" "$nombre" "$id" "$precio"
    return 0
}

baja_producto() {
    local id=""

    printf "\n--- BAJA DE PRODUCTO ---\n"
    read -rp "Ingrese ID a eliminar: " id

    if ! producto_existe "$id"; then
        printf "[Error en baja_producto]: El producto con ID '%s' no existe.\n" "$id" >&2
        return 1
    fi

    local arch_temp
    arch_temp=$(mktemp)

    local prod_id prod_nombre prod_precio
    while IFS=$'\t' read -r prod_id prod_nombre prod_precio; do
        if [[ "$prod_id" != "$id" ]]; then
            printf "%s\t%s\t%s\n" "$prod_id" "$prod_nombre" "$prod_precio" >> "$arch_temp"
        fi
    done < "$ARCH_PRODUCTOS"

    mv "$arch_temp" "$ARCH_PRODUCTOS"
    printf "Producto con ID '%s' eliminado correctamente.\n" "$id"
    return 0
}

editar_producto() {
    local id=""

    printf "\n--- EDITAR PRODUCTO ---\n"
    read -rp "Ingrese ID del producto a modificar: " id

    if ! producto_existe "$id"; then
        printf "[Error en editar_producto]: El producto con ID '%s' no existe.\n" "$id" >&2
        return 1
    fi

    local nuevo_nombre=""
    local nuevo_precio=""

    read -rp "Ingrese nuevo Nombre: " nuevo_nombre
    read -rp "Ingrese nuevo Precio: " nuevo_precio

    if [[ -z "$nuevo_nombre" || -z "$nuevo_precio" ]]; then
        printf "[Error en editar_producto]: El nombre y precio no pueden estar vacios.\n" >&2
        return 1
    fi

    local arch_temp
    arch_temp=$(mktemp)

    local prod_id prod_nombre prod_precio
    while IFS=$'\t' read -r prod_id prod_nombre prod_precio; do
        if [[ "$prod_id" == "$id" ]]; then
            printf "%s\t%s\t%s\n" "$id" "$nuevo_nombre" "$nuevo_precio" >> "$arch_temp"
        else
            printf "%s\t%s\t%s\n" "$prod_id" "$prod_nombre" "$prod_precio" >> "$arch_temp"
        fi
    done < "$ARCH_PRODUCTOS"

    mv "$arch_temp" "$ARCH_PRODUCTOS"
    printf "Producto con ID '%s' modificado exitosamente.\n" "$id"
    return 0
}

mostrar_inventario() {
    printf "\n--- INVENTARIO DE PRODUCTOS (%s) ---\n" "$ARCH_PRODUCTOS"

    if [[ ! -s "$ARCH_PRODUCTOS" ]]; then
        printf "No hay productos registrados en el archivo.\n"
        return 0
    fi

    printf "%-8s | %-25s | %-12s\n" "ID" "NOMBRE" "PRECIO"
    printf "%s\n" "----------------------------------------------------"

    local id nombre precio
    while IFS=$'\t' read -r id nombre precio; do
        [[ -z "$id" ]] && continue
        printf "%-8s | %-25s | $%-12s\n" "$id" "$nombre" "$precio"
    done < "$ARCH_PRODUCTOS"
}

# ------------------------------------------------------------------------------
# Generación de Reporte HTML
# ------------------------------------------------------------------------------
generar_reporte_html() {
    local salida="productos.html"
    printf "\nGenerando reporte en '%s'...\n" "$salida"

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

    if [[ -s "$ARCH_PRODUCTOS" ]]; then
        local id nombre precio
        while IFS=$'\t' read -r id nombre precio; do
            [[ -z "$id" ]] && continue
            cat <<EOF >> "$salida"
                <tr>
                    <td>$id</td>
                    <td>$nombre</td>
                    <td class="precio">\$$precio</td>
                </tr>
EOF
        done < "$ARCH_PRODUCTOS"
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

    printf "Reporte generado con exito. Puede abrir '%s' en su navegador.\n" "$salida"
}

# ------------------------------------------------------------------------------
# Menú Principal de Productos (tras autenticación)
# ------------------------------------------------------------------------------
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
                ;;
            *)
                printf "\nOpcion invalida. Intente nuevamente.\n"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Menú de Entrada (Login / Registro)
# ------------------------------------------------------------------------------
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
                ;;
            *)
                printf "\nOpcion invalida. Intente nuevamente.\n"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Punto de Entrada
# ------------------------------------------------------------------------------
main() {
    inicializar_archivos
    menu_inicio
    return 0
}

main
