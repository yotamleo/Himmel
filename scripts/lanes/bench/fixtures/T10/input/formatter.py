def format_currency(amount):
    return "$%.2f" % amount


def format_percent(value):
    return "%.1f%%" % (value * 100)


def format_list(items):
    return ", ".join(str(item) for item in items)
