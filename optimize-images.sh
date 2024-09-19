#!/bin/bash

# Function to convert a single file to WebP
convert_to_webp() {
    local input_file="$1"
    local output_file="${input_file%.*}.webp"

    if [ "$input_file" != "$output_file" ]; then
        echo "Converting $input_file to WebP..."
        cwebp "$input_file" -o "$output_file"

        if [ $? -eq 0 ]; then
            echo "Conversion successful: $output_file"
        else
            echo "Conversion failed for $input_file"
        fi
    fi
}

# Function to recursively process directories
process_directory() {
    local dir="$1"

    # Loop through all files in the current directory
    for file in "$dir"/*; do
        if [ -d "$file" ]; then
            # If it's a directory, recursively process it
            process_directory "$file"
        elif [ -f "$file" ]; then
            # If it's a file, check if it's JPG or PNG (case-insensitive)
            case "$(echo "$file" | tr '[:upper:]' '[:lower:]')" in
                *.jpg|*.jpeg|*.png)
                    convert_to_webp "$file"
                    ;;
            esac
        fi
    done
}

# Start processing from the current directory
process_directory "."

echo "Conversion process completed."