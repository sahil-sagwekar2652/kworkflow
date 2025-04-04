include "${KW_LIB_DIR}/lib/kw_config_loader.sh"
include "${KW_LIB_DIR}/lib/kwlib.sh"
include "${KW_LIB_DIR}/lib/kw_db.sh"
include "${KW_LIB_DIR}/lib/kw_string.sh"
include "${KW_LIB_DIR}/lib/kw_time_and_date.sh"

# Hash containing command line options
declare -gA options_values

MAX_TAG_LENGTH=32
MAX_DESCRIPTION_LENGTH=512

# Pomodoro manager function.
function pomodoro_main()
{
  local flag
  local ret

  flag=${flag:-'SILENT'}

  if [[ -z "$*" ]]; then
    complain 'Please, provide an argument'
    pomodoro_help "$@"
    exit 22 # EINVAL
  fi

  parse_pomodoro "$@"
  if [[ "$?" -gt 0 ]]; then
    complain "${options_values['ERROR']}"
    pomodoro_help "$@"
    exit 22 # EINVAL
  fi

  [[ -n "${options_values['VERBOSE']}" ]] && flag='VERBOSE'

  if [[ -n "${options_values['REPEAT_PREVIOUS']}" ]]; then
    fetch_last_pomodoro_session "$flag"
    ret="$?"
    if [[ "$ret" != 0 ]]; then
      complain "Failed to fetch last Pomodoro session: ${options_values[ERROR]}"
      return "$ret"
    fi

    confirm_repeat_last_pomodoro_session
    ret="$?"
    if [[ "$ret" == 125 ]]; then
      warning 'Repeat last Pomodoro session aborted.'
      return 125 # ECANCELED
    fi
    say "Repeating session!"
  fi

  if [[ -n "${options_values[SHOW_TIMER]}" ]]; then
    show_active_pomodoro_timebox "$flag"
    return 0
  fi

  if [[ -n "${options_values[SHOW_TAGS]}" ]]; then
    show_tags "$flag"
    return 0
  fi

  if [[ -n "${options_values['TAG']}" ]]; then
    register_tag "$flag" "${options_values['TAG']}"
  fi

  if [[ -n "${options_values['TIMER']}" ]]; then
    timer_thread "$flag" &
  fi
}

# This function inspects the Pomodoro file, and based on each line, information
# tells the user the current status of his work section.
function show_active_pomodoro_timebox()
{
  local flag="$1"
  local current_timestamp
  local start_date
  local start_time
  local duration
  local timestamp
  local elapsed_time
  local remaining_time

  [[ "$flag" == 'VERBOSE' ]] && flag='CMD_SUBSTITUTION_VERBOSE'

  current_timestamp=$(get_timestamp_sec)

  while IFS=$'\n' read -r raw_active_timebox && [[ -n "${raw_active_timebox}" ]]; do
    start_date=$(printf '%s' "${raw_active_timebox}" | cut -d '|' -f1)
    start_time=$(printf '%s' "${raw_active_timebox}" | cut -d '|' -f2)
    duration=$(printf '%s' "${raw_active_timebox}" | cut -d '|' -f3)

    start_date=$(printf '%s' "${start_date}" | sed 's/-/\//g')
    timestamp=$(date --date="${start_date} ${start_time}" '+%s')
    elapsed_time=$((current_timestamp - timestamp))
    remaining_time=$((duration - elapsed_time))

    say "Started at: ${start_time} [${start_date}]"
    say '- Elapsed time:' "$(secs_to_arbitrarily_long_hours_mins_secs "${elapsed_time}")"
    say '- You still have' "$(secs_to_arbitrarily_long_hours_mins_secs "${remaining_time}")"
  done <<< "$(select_from 'active_timebox' '"date","time","duration"' '' '' '' "$flag")"
}

# Show registered tags with number identification.
function show_tags()
{
  local flag=${1:-'SILENT'}
  local tags
  local cmd
  declare -A condition_array

  [[ "$flag" == 'VERBOSE' ]] && flag='CMD_SUBSTITUTION_VERBOSE'

  condition_array=(['active']='1')
  tags=$(select_from 'tag' '"id" AS "ID", "name" AS "Name"' '.mode column' 'condition_array' 'id' "$flag")
  if [[ -z "$tags" ]]; then
    say 'You did not register any tag yet'
    return 0
  fi

  say 'TAGS:'
  printf '%s\n' "$tags"
}

# Register a new tag if it is not yet defined.
#
# @tag: tag name
function register_tag()
{
  local flag="${1:-SILENT}"
  local tag="$2"

  if ! is_tag_already_registered "$flag" "$tag"; then
    insert_into 'tag' "('name')" "('${tag}')" '' "$flag"
  fi
}

# Search in a file for a specific tag name. If it finds, it returns 0;
# otherwise, return a positive number.
#
# @tag_name: Tag name
#
# Return:
# Return 0 if it finds a match, or a value greater than 0 if it does not find
# anything.
function is_tag_already_registered()
{
  local flag="${1:-SILENT}"
  local tag_name="$2"
  local is_tag_registered=''
  local cmd

  [[ "$flag" == 'VERBOSE' ]] && flag='CMD_SUBSTITUTION_VERBOSE'

  is_tag_registered=$(select_from "tag WHERE name IS '${tag_name}'" '' '' '' '' "$flag")

  [[ -n "${is_tag_registered}" ]] && return 0
  return 1 # EPERM
}

# This is the thread function that will be used to notify when the Pomodoro
# section achieves its end. Do not add anything that can print a character
# here; otherwise, it can be visible to users. This function captures the
# current timestamp and uses it to register itself in the Pomodoro log file.
function timer_thread()
{
  local flag="$1"
  local timestamp

  timestamp=$(get_timestamp_sec)

  flag=${flag:-'SILENT'}

  if [[ -z "${options_values['TAG']}" ]]; then
    options_values['TAG']='NO_TAG'
  fi
  register_data_for_report "$flag"

  cmd_manager "$flag" "sleep ${options_values['TIMER']}"
  alert_completion "Pomodoro: Your ${options_values['TIMER']} timebox ended" '--alert=vs'

  exit 0
}

# This function registers the tag name, the timer value, the starting time and
# the description (if there is one) in the local database.
function register_data_for_report()
{
  local flag=${1:-'SILENT'}
  local start_date
  local start_time
  local duration
  local description
  local columns='("tag_name","date","time","duration","description")'
  local -a values=()
  local formatted_data

  # Organize data to be inserted
  start_date=$(date +%Y-%m-%d)
  start_time=$(date +%H:%M:%S)
  duration=$(timebox_to_sec "${options_values['TIMER']}")
  description="${options_values['DESCRIPTION']}"
  [[ -z "$description" ]] && description='NULL'
  values=("${options_values['TAG']}" "${start_date}" "${start_time}" "$duration" "$description")

  # Format the data and insert it into the database
  formatted_data="$(format_values_db 5 "${values[@]}")"
  insert_into '"pomodoro_report"' "$columns" "${formatted_data}" '' "$flag"
}

# This function checks if the time passed as argument is a valid one, i.e, is
# is an integer ended in h, m or s.
#
# @time: The time to check
#
# Return:
# 0 if the time is valid an 22 otherwise.
function is_valid_time()
{
  local time=$1

  if [[ ! "$time" =~ ^[0-9]+(h|m|s)$ ]]; then
    options_values['ERROR']="Invalid time: ${time}"
    return 22 # EINVAL
  fi

  if [[ "$time" =~ ^0+(h|m|s)$ ]]; then
    options_values['ERROR']='Time should be bigger than zero'
    return 22 # EINVAL
  fi

  return 0
}

# This function checks if the argument passed to the option is not another option.
#
# @argument: The argument to check
# @option: Option name
#
# Return:
# 0 if the argument is valid an 22 otherwise.
function is_valid_argument()
{
  local argument=$1
  local option=$2

  if [[ "$argument" =~ ^(--.*|-.*) ]]; then
    options_values['ERROR']="Invalid ${option} argument: ${argument}"
    return 22 # EINVAL
  fi

  return 0
}

# This function returns a tag name given a tag value. If the tag value
# is a number and there is a correspondent tag ID, it prints the tag name.
# Otherwise, it prints the value passed as argument.
#
# @value: An integer number
#
# Return:
# If @value is not a number, prints @value. If @value is number, prints tag name
# if correspondent tag ID exists and returns 0. If fails, return 22 (EINVAL).
function get_tag_name()
{
  local value="$1"
  local tag
  declare -A condition_array

  # Basic check
  [[ -z "$value" ]] && return 22 # EINVAL

  if ! str_is_a_number "$value"; then
    printf '%s\n' "$value"
    return 0
  fi

  condition_array=(['id']="$value")
  tag=$(select_from 'tag' 'name' '' 'condition_array')
  if [[ -z "$tag" ]]; then
    options_values['ERROR']="There is no tag with ID: ${value}"
    return 22 # EINVAL
  fi

  printf '%s\n' "$tag"
  return 0
}

# This function fetches the last pomodoro session from the database, if there is
# one, and sets the `TIMER`, `TAG`, and `DESCRIPTION` options values
# accordingly, preparing to repeat the last session.
#
# @flag Flag to control function output.
#
# Return:
# If there is a last pomodoro session, returns 0. If there isn't a last pomodoro
# session, returns 2 (ENOENT).
function fetch_last_pomodoro_session()
{
  local flag=${1:-'SILENT'}
  local last_pomodoro_session
  local duration_in_secs
  local tag_name
  local description

  [[ "$flag" == 'VERBOSE' ]] && flag='CMD_SUBSTITUTION_VERBOSE'

  last_pomodoro_session=$(select_from 'pomodoro_report' '"duration","tag_name","description"' '' '' 'date DESC, time DESC LIMIT 1' "$flag")
  #last_pomodoro_session=duration|tag_name|description
  if [[ -z "$last_pomodoro_session" ]]; then
    options_values['ERROR']='No previous pomodoro session found'
    return 2 # ENOENT
  fi

  duration_in_secs=$(cut --delimiter='|' --fields=1 <<< "$last_pomodoro_session")
  tag_name=$(cut --delimiter='|' --fields=2 <<< "$last_pomodoro_session")
  description=$(cut --delimiter='|' --fields=3 <<< "$last_pomodoro_session")

  options_values['TIMER']="${duration_in_secs}s"
  options_values['TAG']=$(cut --delimiter='|' --fields=2 <<< "$last_pomodoro_session")
  options_values['DESCRIPTION']=$(cut --delimiter='|' --fields=3 <<< "$last_pomodoro_session")
}

# This function displays the last Pomodoro session fetched with
# `fetch_last_pomodoro_session` and prompts the user to continue or abort
# repeating the last session.
#
# Return:
# Returns 0 if the user continues the operation, and 125 (ECANCELED), otherwise.
function confirm_repeat_last_pomodoro_session()
{
  local duration_in_secs
  local duration

  duration_in_secs="${options_values[TIMER]}"
  duration=$(sec_to_format "${duration_in_secs::-1}" '+%H:%M:%S')

  say 'Last pomodoro session:'
  say "- Duration ${duration}"
  [[ -n ${options_values['TAG']} ]] && say "- Tag: ${options_values['TAG']}"
  [[ -n ${options_values['DESCRIPTION']} ]] && say "- Description: ${options_values['DESCRIPTION']}"

  if [[ $(ask_yN 'Would you like to repeat this session?') =~ '0' ]]; then
    return 125 # ECANCELED
  fi
}

# This function format text to be used for a tag or description.
#
# @text: Text to be formatted
# @option: Option name
#
# Return:
# Prints the formatted text. Returns 0 if the formatting was successful
# and 22 if @option is invalid.
function format_text()
{
  local text="$1"
  local option="$2"
  local text_formatted
  local length
  local max_length

  if [[ "$option" == 'tag' ]]; then
    max_length="${MAX_TAG_LENGTH}"
  elif [[ "$option" == 'description' ]]; then
    max_length="${MAX_DESCRIPTION_LENGTH}"
  else
    return 22 # EINVAL
  fi

  length=$(str_length "$text")
  if [[ "$length" -ge "${max_length}" ]]; then
    text_formatted=$(str_trim "$text" "${max_length}")
  else
    text_formatted=$(str_strip "$text")
  fi
  printf '%s' "${text_formatted}"

  return 0
}

function parse_pomodoro()
{
  local long_options='set-timer:,check-timer,show-tags,tag:,description:,repeat-previous,help,verbose'
  local short_options='t:,c,s,g:,d:,h'
  local options

  options="$(kw_parse "$short_options" "$long_options" "$@")"

  if [[ "$?" != 0 ]]; then
    options_values['ERROR']="$(kw_parse_get_errors 'kw pomodoro' "$short_options" \
      "$long_options" "$@")"
    return 22 # EINVAL
  fi

  eval "set -- ${options}"

  # Default values
  options_values['TIMER']=''
  options_values['SHOW_TIMER']=''
  options_values['SHOW_TAGS']=
  options_values['TAG']=''
  options_values['DESCRIPTION']=''
  options_values['VERBOSE']=''
  options_values['REPEAT_PREVIOUS']=''

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --set-timer | -t)
        is_valid_time "$2" || return "$?"
        options_values['TIMER']="$2"
        shift 2
        ;;
      --check-timer | -c)
        options_values['SHOW_TIMER']=1
        shift
        ;;
      --show-tags | -s)
        options_values['SHOW_TAGS']=1
        shift
        ;;
      --tag | -g)
        if [[ -z "${options_values['TIMER']}" ]]; then
          options_values['ERROR']='--tag requires --set-timer'
          return 22 # EINVAL
        fi
        is_valid_argument "$2" 'tag' || return "$?"
        options_values['TAG']=$(get_tag_name "$2")
        if [[ "$?" -gt 0 ]]; then
          options_values['ERROR']="Invalid tag value: $2"
          return 22 # EINVAL
        fi
        options_values['TAG']=$(format_text "${options_values['TAG']}" 'tag')
        shift 2
        ;;
      --description | -d)
        if [[ -z "${options_values['TIMER']}" || -z "${options_values['TAG']}" ]]; then
          options_values['ERROR']='--description requires --set-timer and --tag'
          return 22 # EINVAL
        fi
        is_valid_argument "$2" 'description' || return "$?"
        options_values['DESCRIPTION']=$(format_text "$2" 'description')
        shift 2
        ;;
      --repeat-previous | -r)
        if [[ -n "${options_values['TIMER']}" || -n "${options_values['SHOW_TIMER']}" || -n "${options_values['SHOW_TAGS']}" ]]; then
          options_values['ERROR']='--repeat-previous can only be accompanied by --verbose'
          return 22 # EINVAL
        fi
        options_values['REPEAT_PREVIOUS']=1
        shift
        ;;
      --verbose)
        options_values['VERBOSE']=1
        shift
        ;;
      --help | -h)
        pomodoro_help "$1"
        exit
        ;;
      *)
        shift
        ;;
    esac
  done
}

function pomodoro_help()
{
  if [[ "$1" == --help ]]; then
    include "$KW_LIB_DIR/help.sh"
    kworkflow_man 'pomodoro'
    return
  fi
  printf '%s\n' 'kw pomodoro:' \
    '  pomodoro (-t|--set-timer) <time>(h|m|s) - Set pomodoro timer' \
    '  pomodoro (-c|--check-timer) - Show elapsed time' \
    '  pomodoro (-s|--show-tags) - Show registered tags' \
    '  pomodoro (-t|--set-timer) <time>(h|m|s) (-g|--tag) <tag> - Set timer with tag' \
    '  pomodoro (-t|--set-timer) <time>(h|m|s) (-g|--tag) <tag> (-d|--description) <desc> - Set timer with tag and description' \
    '  pomodoro (--repeat-previous) - Repeat last Pomodoro session' \
    '  pomodoro (--verbose) - Show a detailed output'
}

load_notification_config
