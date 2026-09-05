def format_currency(amount):
    return "$%.2f" % amount


def format_list(items):
    return ", ".join(str(item).strip() for item in items)
