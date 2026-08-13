#!/usr/bin/env bash

set -u
set -o pipefail

shopt -s nullglob nocaseglob

readonly COLOR_RESOLUTION=350
readonly GRAY_RESOLUTION=350
readonly MONO_RESOLUTION=600
readonly JPEG_QUALITY=95

# Maximum permitted C, M, or Y coverage for a PDF to be considered grayscale.
readonly COLOR_THRESHOLD="0.00001"

# Suffixes that should be preserved when generating new filenames. These are treated as regular expressions.
readonly PRESERVED_SUFFIX_PATTERNS=(
    '_M'
    '_#[0-9]+'
)

converted_count=0
skipped_count=0
failure_count=0

log_success() {
    printf 'Converted + optimized: %s\n' "$1"
}

log_warning() {
    printf 'Warning: %s\n' "$1" >&2
}

log_error() {
    printf 'Error: %s\n' "$1" >&2
}

find_ghostscript() {
    local candidate

    for candidate in gs gswin64c.exe gswin32c.exe; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

if ! GS_BIN=$(find_ghostscript); then
    log_error 'Ghostscript is not installed or no supported Ghostscript executable was found in PATH.'
    log_error 'Expected one of: gs, gswin64c.exe, gswin32c.exe'
    exit 1
fi

readonly GS_BIN

pdf_files=( *.pdf )

if (( ${#pdf_files[@]} == 0 )); then
    log_error 'No PDFs found in the current directory.'
    exit 1
fi

printf 'Converting files...\n'

build_preserved_suffix_regex() {
    local pattern
    local combined=""

    for pattern in "${PRESERVED_SUFFIX_PATTERNS[@]}"; do
        if [[ -n $combined ]]; then
            combined+="|"
        fi

        combined+="$pattern"
    done

    if [[ -z $combined ]]; then
        printf '%s\n' 'a^'
        return
    fi

    printf '(%s)+$\n' "$combined"
}

readonly PRESERVED_SUFFIX_REGEX="$(build_preserved_suffix_regex)"

extract_new_name() {
    local filename=$1
    local base=${filename##*/}
    local main_name
    local preserved_suffix=""

    # Remove the PDF extension, regardless of capitalization.
    base=${base%.[Pp][Dd][Ff]}

    # Remove only a numeric prefix followed by a hyphen, underscore,
    # or whitespace.
    #
    # Examples:
    #   123-Invoice.pdf -> Invoice.pdf
    #   123_Invoice.pdf -> Invoice.pdf
    #   123 Invoice.pdf -> Invoice.pdf
    if [[ $base =~ ^[0-9]+[-_\ ]+(.*)$ ]]; then
        base=${BASH_REMATCH[1]}
    fi

    # Temporarily separate configured suffixes from the main filename.
    if [[ $base =~ $PRESERVED_SUFFIX_REGEX ]]; then
        preserved_suffix=${BASH_REMATCH[0]}
        main_name=${base%"$preserved_suffix"}
    else
        main_name=$base
    fi

    # Maintain the original filename cleanup behavior.
    main_name=${main_name%%_*}
    main_name=${main_name%%[[:space:]]*}

    # Remove trailing whitespace before reattaching suffixes.
    while [[ $main_name == *[[:space:]] ]]; do
        main_name=${main_name%?}
    done

    if [[ -z $main_name ]]; then
        return 1
    fi

    printf '%s%s.pdf\n' "$main_name" "$preserved_suffix"
}

create_unique_output_name() {
    local requested_name=$1
    local source_file=$2
    local stem=${requested_name%.[Pp][Dd][Ff]}
    local candidate=$requested_name
    local counter=2

    while [[ -e $candidate && $candidate != "$source_file" ]]; do
        candidate="${stem}-${counter}.pdf"
        ((counter++))
    done

    printf '%s\n' "$candidate"
}

is_grayscale_pdf() {
    local file=$1
    local coverage_output
    local awk_status

    if ! coverage_output=$(
        "$GS_BIN" \
            -q \
            -dSAFER \
            -dNOPAUSE \
            -dBATCH \
            -sDEVICE=inkcov \
            -o - \
            -f "$file" \
            2>/dev/null
    ); then
        return 2
    fi

    awk -v threshold="$COLOR_THRESHOLD" '
        /CMYK/ {
            found = 1

            cyan    = $1 + 0
            magenta = $2 + 0
            yellow  = $3 + 0

            if (cyan > threshold || magenta > threshold || yellow > threshold) {
                color_found = 1
            }
        }

        END {
            if (!found) {
                exit 2
            }

            if (color_found) {
                exit 1
            }

            exit 0
        }
    ' <<< "$coverage_output"

    awk_status=$?
    return "$awk_status"
}

rename_grayscale_pdf() {
    local source_file=$1
    local destination_file=$2

    if [[ $source_file == "$destination_file" ]]; then
        return 0
    fi

    mv -- "$source_file" "$destination_file"
}

convert_pdf_to_grayscale() {
    local source_file=$1
    local destination_file=$2
    local tmp_file

    if ! tmp_file=$(mktemp "./.pdf-conversion.XXXXXX.pdf"); then
        return 1
    fi

    if ! MSYS2_ARG_CONV_EXCL='-dProcessColorModel=' "$GS_BIN" \
        -dSAFER \
        -sDEVICE=pdfwrite \
        -sOutputFile="$tmp_file" \
        -sColorConversionStrategy=Gray \
        -dProcessColorModel=/DeviceGray \
        -dCompatibilityLevel=1.4 \
        -dCompressFonts=true \
        -dSubsetFonts=true \
        -dDetectDuplicateImages=true \
        -dDownsampleColorImages=true \
        -dColorImageResolution="$COLOR_RESOLUTION" \
        -dColorImageDownsampleThreshold=1.5 \
        -dDownsampleGrayImages=true \
        -dGrayImageResolution="$GRAY_RESOLUTION" \
        -dGrayImageDownsampleThreshold=1.5 \
        -dDownsampleMonoImages=true \
        -dMonoImageResolution="$MONO_RESOLUTION" \
        -dMonoImageDownsampleThreshold=1.5 \
        -dJPEGQ="$JPEG_QUALITY" \
        -dNOPAUSE \
        -dBATCH \
        -dQUIET \
        -f "$source_file"
    then
        rm -f -- "$tmp_file"
        return 1
    fi

    if [[ ! -s $tmp_file ]]; then
        rm -f -- "$tmp_file"
        return 1
    fi

    # Replace the original when its name is already correct.
    if [[ $source_file == "$destination_file" ]]; then
        if mv -f -- "$tmp_file" "$destination_file"; then
            return 0
        fi

        rm -f -- "$tmp_file"
        return 1
    fi

    # Save the completed output before removing the source.
    if ! mv -- "$tmp_file" "$destination_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi

    if ! rm -- "$source_file"; then
        return 2
    fi

    return 0
}

for file in "${pdf_files[@]}"; do
    if ! requested_name=$(extract_new_name "$file"); then
        log_warning "Could not create a valid output name for: $file"
        ((skipped_count++))
        continue
    fi

    new_name=$(create_unique_output_name "$requested_name" "$file")

    is_grayscale_pdf "$file"
    grayscale_status=$?

    case "$grayscale_status" in
        0)
            if rename_grayscale_pdf "$file" "$new_name"; then
                log_success "$new_name"
                ((converted_count++))
            else
                log_error "Could not rename: $file"
                ((failure_count++))
            fi
            ;;

        1)
            convert_pdf_to_grayscale "$file" "$new_name"
            conversion_status=$?

            case "$conversion_status" in
                0)
                    log_success "$new_name"
                    ((converted_count++))
                    ;;

                2)
                    log_success "$new_name"
                    log_warning "Created $new_name but could not remove original $file"
                    ((converted_count++))
                    ;;

                *)
                    log_error "Could not process: $file"
                    ((failure_count++))
                    ;;
            esac
            ;;

        *)
            log_error "Could not determine grayscale status: $file"
            ((failure_count++))
            ;;
    esac
done

printf 'Conversion complete.\n\n'
printf 'Converted: %d\n' "$converted_count"
printf 'Skipped:   %d\n' "$skipped_count"
printf 'Failed:    %d\n' "$failure_count"

if (( failure_count > 0 )); then
    exit 1
fi

exit 0