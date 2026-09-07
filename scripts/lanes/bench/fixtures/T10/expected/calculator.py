def add(a, b):
    return a + b


def subtract(a, b):
    return a - b


def clamp(value, low, high):
    if value < low:
        return low
    if value > high:
        return high
    return value


def multiply(a, b):
    return a * b


def divide(a, b):
    if not isinstance(b, (int, float)):
        raise TypeError("divisor must be numeric")
    if b == 0:
        raise ValueError("cannot divide by zero")
    return a / b
